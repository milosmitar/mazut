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

@Observable
final class DemucsSeparator {

    enum SeparationError: Error { case modelMissing, audioLoad, modelOutput }

    /// Redosled izlaza modela (sources) → StemKind.
    static let modelOrder: [StemKind] = [.drums, .bass, .other, .vocals, .guitar, .piano]

    private(set) var progress: Double = 0
    private(set) var isRunning = false

    private let dsp = DemucsDSP()
    private let overlap = 0.25

    // MARK: - Javni API

    /// Razdvoji pesmu i vrati URL-ove 6 stem .wav fajlova (po StemKind).
    func separate(url: URL) async throws -> [StemKind: URL] {
        await MainActor.run { self.isRunning = true; self.progress = 0 }
        defer { Task { @MainActor in self.isRunning = false } }

        let model = try loadModel()
        let mix = try loadAudio44kStereo(url)                    // [2][total]
        let total = mix[0].count
        let TL = DemucsParams.segmentSamples
        let stride = Int(Double(TL) * (1 - overlap))

        // Izlazni baferi: 6 stemova × 2 kanala × total.
        var out = [[[Float]]](repeating: [[Float]](repeating: [Float](repeating: 0, count: total), count: 2), count: 6)
        var wsum = [Float](repeating: 0, count: total)
        let win = olaWindow(TL)

        let nChunks = max(1, Int(ceil(Double(max(0, total - 1)) / Double(stride))) + 1)
        var chunkIdx = 0
        var pos = 0
        while pos < total {
            let len = min(TL, total - pos)
            var chunk = [[Float]](repeating: [Float](repeating: 0, count: TL), count: 2)
            for c in 0..<2 {
                for i in 0..<len { chunk[c][i] = mix[c][pos + i] }
            }

            let (spec, time) = try predict(model: model, mix: chunk)
            // VAŽNO: Core ML izlazi imaju padding (strides != kontinualno) —
            // npr. time_out kanal stride je 343984, ne 343980. Čitamo preko strides.
            let specP = spec.dataPointer.bindMemory(to: Float.self, capacity: spec.strides[0].intValue)
            let timeP = time.dataPointer.bindMemory(to: Float.self, capacity: time.strides[0].intValue)
            let specStemStride = spec.strides[1].intValue
            let specChStride = spec.strides[2].intValue   // jedan cac kanal (F*T, kontinualno)
            let timeStemStride = time.strides[1].intValue
            let timeChStride = time.strides[2].intValue
            for s in 0..<6 {
                for c in 0..<2 {
                    let reOff = s * specStemStride + (2 * c) * specChStride
                    let imOff = s * specStemStride + (2 * c + 1) * specChStride
                    let wav = dsp.istftChannel(re: specP + reOff, im: specP + imOff)
                    let tOff = s * timeStemStride + c * timeChStride
                    for i in 0..<len {
                        out[s][c][pos + i] += (wav[i] + timeP[tOff + i]) * win[i]
                    }
                }
            }
            for i in 0..<len { wsum[pos + i] += win[i] }

            chunkIdx += 1
            await MainActor.run { self.progress = min(1, Double(chunkIdx) / Double(nChunks)) }
            pos += stride
        }

        // Normalizacija overlap-add.
        for i in 0..<total where wsum[i] > 1e-6 {
            for s in 0..<6 { for c in 0..<2 { out[s][c][i] /= wsum[i] } }
        }

        // Upis 6 .wav fajlova.
        var result: [StemKind: URL] = [:]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("separated", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for s in 0..<6 {
            let kind = Self.modelOrder[s]
            let fileURL = dir.appendingPathComponent("\(kind.rawValue).wav")
            try writeWav(channels: out[s], to: fileURL)
            result[kind] = fileURL
        }
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

    /// Pokreni model za jedan segment. Vraća (spec_out, time_out) MLMultiArray-eve
    /// (čitaju se preko strides u pozivaocu zbog padding-a).
    private func predict(model: MLModel, mix: [[Float]]) throws -> (MLMultiArray, MLMultiArray) {
        let TL = DemucsParams.segmentSamples
        let magFlat = dsp.magnitude(mix: mix)                    // [4*2048*336]

        let magArr = try MLMultiArray(shape: [1, 4, 2048, 336], dataType: .float32)
        magFlat.withUnsafeBufferPointer { src in
            _ = memcpy(magArr.dataPointer, src.baseAddress!, magFlat.count * MemoryLayout<Float>.size)
        }
        let mixArr = try MLMultiArray(shape: [1, 2, NSNumber(value: TL)], dataType: .float32)
        let mixPtr = mixArr.dataPointer.bindMemory(to: Float.self, capacity: 2 * TL)
        for c in 0..<2 { for i in 0..<TL { mixPtr[c * TL + i] = mix[c][i] } }

        let input = try MLDictionaryFeatureProvider(dictionary: ["mag": magArr, "mix": mixArr])
        let result = try model.prediction(from: input)
        guard let spec = result.featureValue(for: "spec_out")?.multiArrayValue,
              let time = result.featureValue(for: "time_out")?.multiArrayValue else {
            throw SeparationError.modelOutput
        }
        return (spec, time)
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

    private func writeWav(channels: [[Float]], to url: URL) throws {
        let n = channels[0].count
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: Double(DemucsParams.sampleRate),
                                channels: 2, interleaved: false)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(DemucsParams.sampleRate),
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        try? FileManager.default.removeItem(at: url)
        let outFile = try AVAudioFile(forWriting: url, settings: settings)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        for c in 0..<2 {
            let dst = buf.floatChannelData![c]
            for i in 0..<n { dst[i] = max(-1, min(1, channels[c][i])) }
        }
        try outFile.write(from: buf)
    }
}
