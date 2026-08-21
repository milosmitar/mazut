//
//  DemucsSeparator.swift
//  Mazut
//
//  On-device separation of a song into 6 stems via htdemucs_6s (Core ML core
//  + vDSP STFT/ISTFT). Processes the whole file in 7.8 s segments with
//  overlap-add, then writes 6 .wav files loaded by StemMixerEngine.
//

import Foundation
import AVFoundation
import CoreML
import Accelerate
import os

@Observable
nonisolated final class DemucsSeparator {

    enum SeparationError: Error { case modelMissing, audioLoad, modelOutput }

    /// Unified logging — visible both in the Xcode console and in Console.app/log
    /// stream (unlike `print`, which only goes to stdout under the debugger).
    private static let log = Logger(subsystem: "com.tarmi.Mazut", category: "separation")

    /// Order of the model's outputs (sources) → StemKind.
    static let modelOrder: [StemKind] = [.drums, .bass, .other, .vocals, .guitar, .piano]

    private(set) var progress: Double = 0
    private(set) var isRunning = false

    private let dsp = DemucsDSP()
    private let overlap = 0.1   // 0.25 → 0.1: ~13% fewer segments, negligible boundary artifact

    // MARK: - Public API

    /// Separate a song and return the URLs of the 6 stem .wav files (by StemKind).
    func separate(url: URL) async throws -> [StemKind: URL] {
        // Cache hit: the song is already separated → return the existing stems immediately.
        let key = try StemCache.key(for: url)
        if let cached = StemCache.stems(for: key) {
            Self.log.notice("[Mazut] cache hit — skipping separation (remove from library to re-run)")
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

        // Positions of all segments.
        var positions: [Int] = []
        var p = 0
        while p < total { positions.append(p); p += stride }
        let nChunks = positions.count

        // --- Streaming output to disk: one AVAudioFile (AAC) per stem + a sliding
        // window instead of a full `out` buffer (714 MB → ~16 MB; critical on a 4 GB device).
        // Segments run left to right, overlap 0.1 → each sample is covered by ≤2 segments,
        // so samples before the next segment's position are final and written immediately. ---
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

        // Sliding window: acc[6][2] and wsumW cover the absolute range [winStart, ...).
        var winStart = 0
        var acc = [[[Float]]](repeating: [[Float]](repeating: [], count: 2), count: 6)
        var wsumW = [Float]()

        // Extend the window to cover up to `end` (absolute index).
        func ensureWindow(upTo end: Int) {
            let add = (end - winStart) - wsumW.count
            guard add > 0 else { return }
            wsumW.append(contentsOf: repeatElement(0, count: add))
            for s in 0..<6 { for c in 0..<2 { acc[s][c].append(contentsOf: repeatElement(0, count: add)) } }
        }

        // Normalize [winStart, end), write to disk, then release the window's prefix.
        // AAC encoding of 6 stems is the main bottleneck → 6 stems in parallel
        // (each its own AVAudioFile + buffer, independent on its own thread).
        func flush(upTo end: Int) throws {
            let count = end - winStart
            guard count > 0 else { return }
            let errLock = NSLock()
            var writeErr: Error?
            DispatchQueue.concurrentPerform(iterations: 6) { s in
                let buf = AVAudioPCMBuffer(pcmFormat: writeFmt, frameCapacity: AVAudioFrameCount(count))!
                buf.frameLength = AVAudioFrameCount(count)
                for c in 0..<2 {
                    let dst = buf.floatChannelData![c]
                    let src = acc[s][c]
                    for i in 0..<count {
                        let w = wsumW[i]
                        dst[i] = w > 1e-6 ? max(-1, min(1, src[i] / w)) : 0
                    }
                }
                do { try writers[s].write(from: buf) }
                catch { errLock.lock(); writeErr = error; errLock.unlock() }
            }
            if let writeErr { throw writeErr }
            wsumW.removeFirst(count)
            for s in 0..<6 { for c in 0..<2 { acc[s][c].removeFirst(count) } }
            winStart = end
        }

        let tWall0 = CFAbsoluteTimeGetCurrent()

        // --- Profiling: sum of durations per component (all measured separately, even
        // though GPU and CPU overlap). The comparison shows whether we're GPU- or CPU-bound. ---
        var tInferSum = 0.0   // GPU: Core ML prediction
        var tStftSum = 0.0    // CPU: makeInput (STFT)
        var tIstftSum = 0.0   // CPU: consume (ISTFT + overlap-add)
        var tWriteSum = 0.0   // CPU: flush (normalization + AAC write of 6 stems)

        // --- Pipeline: while the GPU runs inference for segment i, the CPU works in
        // parallel on ISTFT for segment i-1 and STFT for segment i+1 (A1+A2). Keeps at
        // most 2 outputs in RAM. ---
        if nChunks > 0 {
            var pending: (spec: MLMultiArray, time: MLMultiArray, idx: Int, pos: Int, len: Int)?
            let t0 = CFAbsoluteTimeGetCurrent()
            var nextInput = try makeInput(model: model, mix: mix, pos: positions[0], total: total, TL: TL)
            tStftSum += CFAbsoluteTimeGetCurrent() - t0

            for i in 0..<nChunks {
                try Task.checkCancellation()   // "Cancel" between segments
                let curProvider = nextInput.provider
                let curPos = positions[i]
                let curLen = nextInput.len

                // GPU: inference for the current segment (in parallel with the CPU work below).
                async let inferred = runInference(model, curProvider)

                // CPU (overlapped with inference): consume the previous one + prepare the next.
                if let pend = pending {
                    let tc = CFAbsoluteTimeGetCurrent()
                    ensureWindow(upTo: pend.pos + pend.len)
                    consume(spec: pend.spec, time: pend.time, pos: pend.pos, len: pend.len,
                            winBase: winStart, acc: &acc, wsum: &wsumW, win: win)
                    let tw = CFAbsoluteTimeGetCurrent()
                    tIstftSum += tw - tc
                    // Samples before the next segment's position are final → write and release.
                    try flush(upTo: positions[pend.idx + 1])
                    tWriteSum += CFAbsoluteTimeGetCurrent() - tw
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
                Self.log.debug("[Mazut] segment \(i + 1, privacy: .public)/\(nChunks, privacy: .public): GPU infer \(Int(dtInfer * 1000), privacy: .public)ms")
                await MainActor.run { self.progress = min(1, Double(i + 1) / Double(nChunks)) }
            }
            // Last segment: finalize everything up to the end.
            if let pend = pending {
                let tc = CFAbsoluteTimeGetCurrent()
                ensureWindow(upTo: pend.pos + pend.len)
                consume(spec: pend.spec, time: pend.time, pos: pend.pos, len: pend.len,
                        winBase: winStart, acc: &acc, wsum: &wsumW, win: win)
                let tw = CFAbsoluteTimeGetCurrent()
                tIstftSum += tw - tc
                try flush(upTo: total)
                tWriteSum += CFAbsoluteTimeGetCurrent() - tw
            }
        }

        let wall = CFAbsoluteTimeGetCurrent() - tWall0
        let audioSec = Double(total) / Double(DemucsParams.sampleRate)
        Self.log.notice("\(String(format: "[Mazut] %d seg | audio %.0fs → processing %.1fs (%.2f× realtime)", nChunks, audioSec, wall, audioSec / max(wall, 0.001)), privacy: .public)")
        let n = max(nChunks, 1)
        let cpuPer = (tStftSum + tIstftSum + tWriteSum) / Double(n) * 1000
        Self.log.notice("\(String(format: "[Mazut] profile/segment: GPU %.0fms | STFT %.0fms | ISTFT %.0fms | AAC write %.0fms  (CPU total %.0fms vs GPU %.0fms → %@)", tInferSum / Double(n) * 1000, tStftSum / Double(n) * 1000, tIstftSum / Double(n) * 1000, tWriteSum / Double(n) * 1000, cpuPer, tInferSum / Double(n) * 1000, tInferSum / Double(n) * 1000 > cpuPer ? "GPU-bound" : "CPU-bound"), privacy: .public)")

        StemCache.saveMeta(key: key, name: url.deletingPathExtension().lastPathComponent)
        await StemCache.saveArtwork(key: key, from: url)   // album art → cover.jpg (if present)
        await MainActor.run { self.progress = 1 }
        return result
    }

    // MARK: - Core ML

    private func loadModel() throws -> MLModel {
        guard let url = Bundle.main.url(forResource: "HTDemucs6sCore", withExtension: "mlmodelc") else {
            throw SeparationError.modelMissing
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndGPU      // fp32 → doesn't use the Neural Engine (ANE is fp16)
        return try MLModel(contentsOf: url, configuration: cfg)
    }

    /// Prepare the input for one segment: STFT (mag) + mix → MLFeatureProvider.
    /// Also returns the segment's actual length (the last one may be shorter).
    private func makeInput(model: MLModel, mix: [[Float]], pos: Int, total: Int, TL: Int)
        throws -> (provider: MLFeatureProvider, len: Int) {
        let len = min(TL, total - pos)
        var chunk = [[Float]](repeating: [Float](repeating: 0, count: TL), count: 2)
        for c in 0..<2 { for i in 0..<len { chunk[c][i] = mix[c][pos + i] } }

        let magFlat = dsp.magnitude(mix: chunk)            // STFT + cac magnitude
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

    /// Core ML inference (as a separate async task → overlaps with CPU work).
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

    /// ISTFT (12 in parallel: 6 stems × 2 channels) + overlap-add into the sliding window.
    /// `winBase` is the absolute index of the window's start → write at offset `pos - winBase`.
    private func consume(spec: MLMultiArray, time: MLMultiArray, pos: Int, len: Int,
                         winBase: Int, acc: inout [[[Float]]], wsum: inout [Float], win: [Float]) {
        // spec_out is read STRIDED in the ISTFT (re[k*T+t], stride T). We copy it into a
        // contiguous CPU buffer once (sequential memcpy), so the ISTFT works out of RAM —
        // avoiding strided access into GPU-backed Core ML output memory. (spec_out is
        // contiguous, see README; time_out is read sequentially so it stays accessed via strides.)
        let specStemStride = spec.strides[1].intValue
        let specChStride = spec.strides[2].intValue   // one cac channel (F*T, contiguous)
        let specSize = spec.strides[0].intValue
        var specBuf = [Float](repeating: 0, count: specSize)
        specBuf.withUnsafeMutableBufferPointer { dst in
            memcpy(dst.baseAddress!, spec.dataPointer, specSize * MemoryLayout<Float>.size)
        }

        let timeP = time.dataPointer.bindMemory(to: Float.self, capacity: time.strides[0].intValue)
        let timeStemStride = time.strides[1].intValue
        let timeChStride = time.strides[2].intValue

        // Parallel ISTFT: 12 independent (stem, channel) pairs → each writes to its own slot.
        var waves = [[Float]](repeating: [], count: 12)
        specBuf.withUnsafeBufferPointer { sp in
            let specP = sp.baseAddress!
            waves.withUnsafeMutableBufferPointer { wbuf in
                DispatchQueue.concurrentPerform(iterations: 12) { j in
                    let s = j / 2, c = j % 2
                    let reOff = s * specStemStride + (2 * c) * specChStride
                    let imOff = s * specStemStride + (2 * c + 1) * specChStride
                    wbuf[j] = dsp.istftChannel(re: specP + reOff, im: specP + imOff)
                }
            }
        }

        // Sequential overlap-add into the window (shares the common `acc`/`wsum`).
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

    /// Load any audio file and return [2][N] Float at 44100 Hz (stereo).
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

    /// AAC encoder bitrate per stem (stereo). 192 kbps ≈ transparent,
    /// and ~7× smaller than 16-bit PCM .wav (1411 kbps). Writing is now incremental
    /// (sliding window in `separate`), so there's no separate `writeStem` function.
    private static let aacBitRate = 192_000
}
