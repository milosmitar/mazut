//
//  DemucsSeparator.swift
//  Mazut
//
//  On-device razdvajanje pesme na 6 stemova preko htdemucs_6s (Core ML core
//  + vDSP STFT/ISTFT). Procesira ceo fajl u 7.8 s segmentima sa overlap-add,
//  pa upisuje 6 .wav fajlova koje učitava StemMixerEngine.
//

import Foundation
import AVFoundation
import CoreML
import Accelerate
import os

@Observable
nonisolated final class DemucsSeparator {

    enum SeparationError: Error { case modelMissing, audioLoad, modelOutput }

    /// Unified logging — vidljivo i u Xcode konzoli i u Console.app/stream-u
    /// (za razliku od `print`, koji ide samo na stdout pod debuggerom).
    private static let log = Logger(subsystem: "com.tarmi.Mazut", category: "separacija")

    /// Redosled izlaza modela (sources) → StemKind.
    static let modelOrder: [StemKind] = [.drums, .bass, .other, .vocals, .guitar, .piano]

    private(set) var progress: Double = 0
    private(set) var isRunning = false

    private let dsp = DemucsDSP()
    private let overlap = 0.1   // 0.25 → 0.1: ~13% manje segmenata, zanemarljiv artefakt na granicama

    // MARK: - Javni API

    /// Razdvoji pesmu i vrati URL-ove 6 stem .wav fajlova (po StemKind).
    func separate(url: URL) async throws -> [StemKind: URL] {
        Self.log.notice("[Mazut] separate() pozvan za \(url.lastPathComponent, privacy: .public)")
        // Keš pogodak: pesma je već razdvojena → vrati postojeće stemove odmah.
        let key = try StemCache.key(for: url)
        if let cached = StemCache.stems(for: key) {
            Self.log.notice("[Mazut] keš pogodak — preskačem razdvajanje (obriši iz biblioteke da bi ponovo merio)")
            return cached
        }

        await MainActor.run { self.isRunning = true; self.progress = 0 }
        defer { Task { @MainActor in self.isRunning = false } }

        let model = try loadModel()
        let mix = try loadAudio44kStereo(url)                    // [2][total]
        let total = mix[0].count
        let TL = DemucsParams.segmentSamples
        let stride = Int(Double(TL) * (1 - overlap))

        let win = olaWindow(TL)

        // Pozicije svih segmenata.
        var positions: [Int] = []
        var p = 0
        while p < total { positions.append(p); p += stride }
        let nChunks = positions.count
        Self.log.notice("[Mazut] učitan zvuk: \(total, privacy: .public) sample-ova, \(nChunks, privacy: .public) segmenata — počinjem")

        // --- Streaming izlaz na disk: po jedan AVAudioFile (AAC) po stemu + klizni
        // prozor umesto punog `out` bafera (714 MB → ~16 MB; kritično na 4 GB uređaju).
        // Segmenti idu s leva na desno, overlap 0.1 → svaki sample pokriva ≤2 segmenta,
        // pa su sample-ovi pre pozicije sledećeg segmenta finalni i upisuju se odmah. ---
        let dir = StemCache.directory(for: key)
        let writeFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: Double(DemucsParams.sampleRate),
                                     channels: 2, interleaved: false)!
        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(DemucsParams.sampleRate),
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: Self.aacBitRate,
        ]
        var writers: [AVAudioFile] = []
        var result: [StemKind: URL] = [:]
        for s in 0..<6 {
            let kind = Self.modelOrder[s]
            let fileURL = dir.appendingPathComponent("\(kind.rawValue).\(StemCache.stemExtension)")
            try? FileManager.default.removeItem(at: fileURL)
            writers.append(try AVAudioFile(forWriting: fileURL, settings: aacSettings))
            result[kind] = fileURL
        }

        // Klizni prozor: acc[6][2] i wsumW pokrivaju apsolutni opseg [winStart, ...).
        var winStart = 0
        var acc = [[[Float]]](repeating: [[Float]](repeating: [], count: 2), count: 6)
        var wsumW = [Float]()

        // Proširi prozor da pokrije do `end` (apsolutni indeks).
        func ensureWindow(upTo end: Int) {
            let add = (end - winStart) - wsumW.count
            guard add > 0 else { return }
            wsumW.append(contentsOf: repeatElement(0, count: add))
            for s in 0..<6 { for c in 0..<2 { acc[s][c].append(contentsOf: repeatElement(0, count: add)) } }
        }

        // Normalizuj [winStart, end), upiši na disk, pa oslobodi prefiks prozora.
        func flush(upTo end: Int) throws {
            let count = end - winStart
            guard count > 0 else { return }
            let buf = AVAudioPCMBuffer(pcmFormat: writeFmt, frameCapacity: AVAudioFrameCount(count))!
            buf.frameLength = AVAudioFrameCount(count)
            for s in 0..<6 {
                for c in 0..<2 {
                    let dst = buf.floatChannelData![c]
                    let src = acc[s][c]
                    for i in 0..<count {
                        let w = wsumW[i]
                        dst[i] = w > 1e-6 ? max(-1, min(1, src[i] / w)) : 0
                    }
                }
                try writers[s].write(from: buf)
            }
            wsumW.removeFirst(count)
            for s in 0..<6 { for c in 0..<2 { acc[s][c].removeFirst(count) } }
            winStart = end
        }

        let tWall0 = CFAbsoluteTimeGetCurrent()

        // --- Profil: zbir trajanja po komponenti (sve mereno zasebno, iako su
        // GPU i CPU preklopljeni). Poređenje pokazuje da li smo GPU- ili CPU-bound. ---
        var tInferSum = 0.0   // GPU: Core ML prediction
        var tStftSum = 0.0    // CPU: makeInput (STFT)
        var tIstftSum = 0.0   // CPU: consume (ISTFT + overlap-add) + upis

        // --- Pipeline: dok GPU radi inferenciju segmenta i, CPU paralelno radi
        // ISTFT segmenta i-1 i STFT segmenta i+1 (A1+A2). Drži najviše 2 izlaza u RAM-u. ---
        if nChunks > 0 {
            var pending: (spec: MLMultiArray, time: MLMultiArray, idx: Int, pos: Int, len: Int)?
            let t0 = CFAbsoluteTimeGetCurrent()
            var nextInput = try makeInput(model: model, mix: mix, pos: positions[0], total: total, TL: TL)
            tStftSum += CFAbsoluteTimeGetCurrent() - t0

            for i in 0..<nChunks {
                try Task.checkCancellation()   // „Odustani" između segmenata
                let curProvider = nextInput.provider
                let curPos = positions[i]
                let curLen = nextInput.len

                // GPU: inferencija tekućeg segmenta (paralelno sa CPU radom ispod).
                async let inferred = runInference(model, curProvider)

                // CPU (preklopljeno sa inferencijom): potroši prethodni + pripremi sledeći.
                if let pend = pending {
                    let tc = CFAbsoluteTimeGetCurrent()
                    ensureWindow(upTo: pend.pos + pend.len)
                    consume(spec: pend.spec, time: pend.time, pos: pend.pos, len: pend.len,
                            winBase: winStart, acc: &acc, wsum: &wsumW, win: win)
                    // sample-ovi < pozicija sledećeg segmenta su finalni → upiši i oslobodi.
                    try flush(upTo: positions[pend.idx + 1])
                    tIstftSum += CFAbsoluteTimeGetCurrent() - tc
                    pending = nil
                }
                if i + 1 < nChunks {
                    let ts = CFAbsoluteTimeGetCurrent()
                    nextInput = try makeInput(model: model, mix: mix, pos: positions[i + 1], total: total, TL: TL)
                    tStftSum += CFAbsoluteTimeGetCurrent() - ts
                }

                let (spec, time, dtInfer) = try await inferred
                tInferSum += dtInfer
                pending = (spec, time, i, curPos, curLen)
                Self.log.notice("[Mazut] segment \(i + 1, privacy: .public)/\(nChunks, privacy: .public): GPU infer \(Int(dtInfer * 1000), privacy: .public)ms")
                await MainActor.run { self.progress = min(1, Double(i + 1) / Double(nChunks)) }
            }
            // Poslednji segment: finalizuj sve do kraja.
            if let pend = pending {
                let tc = CFAbsoluteTimeGetCurrent()
                ensureWindow(upTo: pend.pos + pend.len)
                consume(spec: pend.spec, time: pend.time, pos: pend.pos, len: pend.len,
                        winBase: winStart, acc: &acc, wsum: &wsumW, win: win)
                try flush(upTo: total)
                tIstftSum += CFAbsoluteTimeGetCurrent() - tc
            }
        }

        let wall = CFAbsoluteTimeGetCurrent() - tWall0
        let audioSec = Double(total) / Double(DemucsParams.sampleRate)
        Self.log.notice("\(String(format: "[Mazut] %d seg | zvuk %.0fs → obrada %.1fs (%.2f× realtime)", nChunks, audioSec, wall, audioSec / max(wall, 0.001)), privacy: .public)")
        let n = max(nChunks, 1)
        Self.log.notice("\(String(format: "[Mazut] profil/segment: GPU infer %.0fms | STFT %.0fms | ISTFT+OLA+upis %.0fms  (CPU ukupno %.0fms vs GPU %.0fms → %@)", tInferSum / Double(n) * 1000, tStftSum / Double(n) * 1000, tIstftSum / Double(n) * 1000, (tStftSum + tIstftSum) / Double(n) * 1000, tInferSum / Double(n) * 1000, tInferSum > (tStftSum + tIstftSum) ? "GPU-bound" : "CPU-bound"), privacy: .public)")

        StemCache.saveMeta(key: key, name: url.deletingPathExtension().lastPathComponent)
        await StemCache.saveArtwork(key: key, from: url)   // album art → cover.jpg (ako postoji)
        await MainActor.run { self.progress = 1 }
        return result
    }

    // MARK: - Core ML

    private func loadModel() throws -> MLModel {
        guard let url = Bundle.main.url(forResource: "HTDemucs6sCore", withExtension: "mlmodelc") else {
            throw SeparationError.modelMissing
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndGPU      // fp32 → ne koristi Neural Engine (ANE je fp16)
        return try MLModel(contentsOf: url, configuration: cfg)
    }

    /// Pripremi ulaz za jedan segment: STFT (mag) + mix → MLFeatureProvider.
    /// Vraća i stvarnu dužinu segmenta (poslednji može biti kraći).
    private func makeInput(model: MLModel, mix: [[Float]], pos: Int, total: Int, TL: Int)
        throws -> (provider: MLFeatureProvider, len: Int) {
        let len = min(TL, total - pos)
        var chunk = [[Float]](repeating: [Float](repeating: 0, count: TL), count: 2)
        for c in 0..<2 { for i in 0..<len { chunk[c][i] = mix[c][pos + i] } }

        let magFlat = dsp.magnitude(mix: chunk)            // STFT + cac magnituda
        let magArr = try MLMultiArray(shape: [1, 4, 2048, 336], dataType: .float32)
        magFlat.withUnsafeBufferPointer { src in
            _ = memcpy(magArr.dataPointer, src.baseAddress!, magFlat.count * MemoryLayout<Float>.size)
        }
        let mixArr = try MLMultiArray(shape: [1, 2, NSNumber(value: TL)], dataType: .float32)
        let mixPtr = mixArr.dataPointer.bindMemory(to: Float.self, capacity: 2 * TL)
        for c in 0..<2 { for i in 0..<TL { mixPtr[c * TL + i] = chunk[c][i] } }

        let provider = try MLDictionaryFeatureProvider(dictionary: ["mag": magArr, "mix": mixArr])
        return (provider, len)
    }

    /// Core ML inferencija (kao zaseban async task → preklapa se sa CPU radom).
    private func runInference(_ model: MLModel, _ provider: MLFeatureProvider)
        async throws -> (MLMultiArray, MLMultiArray, Double) {
        let t0 = CFAbsoluteTimeGetCurrent()
        let result = try await model.prediction(from: provider)
        let dt = CFAbsoluteTimeGetCurrent() - t0
        guard let spec = result.featureValue(for: "spec_out")?.multiArrayValue,
              let time = result.featureValue(for: "time_out")?.multiArrayValue else {
            throw SeparationError.modelOutput
        }
        return (spec, time, dt)
    }

    /// ISTFT (12 paralelnih: 6 stemova × 2 kanala) + overlap-add u klizni prozor.
    /// `winBase` je apsolutni indeks početka prozora → upis na offset `pos - winBase`.
    private func consume(spec: MLMultiArray, time: MLMultiArray, pos: Int, len: Int,
                         winBase: Int, acc: inout [[[Float]]], wsum: inout [Float], win: [Float]) {
        // Core ML izlazi imaju padding (strides != kontinualno) — čitamo preko strides.
        let specP = spec.dataPointer.bindMemory(to: Float.self, capacity: spec.strides[0].intValue)
        let timeP = time.dataPointer.bindMemory(to: Float.self, capacity: time.strides[0].intValue)
        let specStemStride = spec.strides[1].intValue
        let specChStride = spec.strides[2].intValue   // jedan cac kanal (F*T, kontinualno)
        let timeStemStride = time.strides[1].intValue
        let timeChStride = time.strides[2].intValue

        // Paralelni ISTFT: 12 nezavisnih (stem,kanal) → svaki piše u svoj slot.
        var waves = [[Float]](repeating: [], count: 12)
        waves.withUnsafeMutableBufferPointer { wbuf in
            DispatchQueue.concurrentPerform(iterations: 12) { j in
                let s = j / 2, c = j % 2
                let reOff = s * specStemStride + (2 * c) * specChStride
                let imOff = s * specStemStride + (2 * c + 1) * specChStride
                wbuf[j] = dsp.istftChannel(re: specP + reOff, im: specP + imOff)
            }
        }

        // Sekvencijalni overlap-add u prozor (deli zajednički `acc`/`wsum`).
        let base = pos - winBase
        for j in 0..<12 {
            let s = j / 2, c = j % 2
            let wav = waves[j]
            let tOff = s * timeStemStride + c * timeChStride
            for i in 0..<len {
                acc[s][c][base + i] += (wav[i] + timeP[tOff + i]) * win[i]
            }
        }
        for i in 0..<len { wsum[base + i] += win[i] }
    }

    // MARK: - Audio I/O

    private func olaWindow(_ length: Int) -> [Float] {
        var w = [Float](repeating: 0, count: length)
        for n in 0..<length { w[n] = 0.5 - 0.5 * cos(2 * Float.pi * Float(n) / Float(length)) + 1e-3 }
        return w
    }

    /// Učita bilo koji audio fajl i vrati [2][N] Float na 44100 Hz (stereo).
    private func loadAudio44kStereo(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: Double(DemucsParams.sampleRate),
                                   channels: 2, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw SeparationError.audioLoad
        }
        let srcBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                      frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: srcBuf)

        let ratio = target.sampleRate / file.processingFormat.sampleRate
        let outCap = AVAudioFrameCount(Double(srcBuf.frameLength) * ratio) + 4096
        let dstBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap)!

        var fed = false
        var err: NSError?
        converter.convert(to: dstBuf, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return srcBuf
        }
        if let err { throw err }

        let n = Int(dstBuf.frameLength)
        let ch = dstBuf.floatChannelData!
        let left = Array(UnsafeBufferPointer(start: ch[0], count: n))
        let right = target.channelCount > 1 ? Array(UnsafeBufferPointer(start: ch[1], count: n)) : left
        return [left, right]
    }

    /// Bitrate AAC enkodera po stemu (stereo). 192 kbps ≈ transparentno,
    /// a ~7× manje od 16-bit PCM .wav (1411 kbps). Upis je sada inkrementalan
    /// (klizni prozor u `separate`), pa nema zasebne `writeStem` funkcije.
    private static let aacBitRate = 192_000
}
