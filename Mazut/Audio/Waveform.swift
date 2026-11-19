//
//  Waveform.swift
//  Mazut
//
//  Overview waveform of a song for the player timeline: loudness (RMS) of the
//  mix of all stems in ~23 ms buckets (1024 samples @ 44.1 kHz), normalised to
//  the loudest bucket and stored as one byte per bucket — ~10 k bytes for a
//  4-minute song. RMS rather than peak: mastered songs peak near full scale
//  almost everywhere, so a peak waveform would be a solid block.
//
//  Built once per song in the background, cached as waveform-v1.bin in the
//  song's cache folder (deleted with the song). Buckets map linearly onto the
//  song's duration, so no header is needed.
//

import Foundation
import AVFoundation
import Accelerate

nonisolated enum Waveform {

    static let samplesPerBucket = 1024
    private static let fileName = "waveform-v1.bin"

    static func load(songID: String) -> [UInt8]? {
        guard let dir = StemCache.existingDirectory(for: songID),
              let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)),
              !data.isEmpty else { return nil }
        return [UInt8](data)
    }

    static func save(_ levels: [UInt8], songID: String) {
        // Song deleted meanwhile → don't resurrect its folder.
        guard let dir = StemCache.existingDirectory(for: songID) else { return }
        try? Data(levels).write(to: dir.appendingPathComponent(fileName))
    }

    /// Levels (0…255) from the sum of all stems, or nil if nothing could be
    /// read or the calling task was cancelled.
    static func build(stems: [StemKind: URL]) -> [UInt8]? {
        let files = stems.values.compactMap { try? AVAudioFile(forReading: $0) }
        guard let first = files.first else { return nil }
        let chunk = AVAudioFrameCount(samplesPerBucket * 256)
        let buffers = files.compactMap {
            AVAudioPCMBuffer(pcmFormat: $0.processingFormat, frameCapacity: chunk)
        }
        guard buffers.count == files.count else { return nil }

        var mix = [Float](repeating: 0, count: Int(chunk))
        var rms: [Float] = []
        rms.reserveCapacity(Int(first.length) / samplesPerBucket + 1)

        while true {
            if Task.isCancelled { return nil }
            var n = Int(chunk)
            for (file, buffer) in zip(files, buffers) {
                do { try file.read(into: buffer, frameCount: chunk) } catch { buffer.frameLength = 0 }
                n = min(n, Int(buffer.frameLength))
            }
            guard n > 0 else { break }

            // Sum every channel of every stem (scale is irrelevant — normalised below).
            vDSP_vclr(&mix, 1, vDSP_Length(n))
            for buffer in buffers {
                guard let ch = buffer.floatChannelData else { continue }
                for c in 0..<Int(buffer.format.channelCount) {
                    vDSP_vadd(mix, 1, ch[c], 1, &mix, 1, vDSP_Length(n))
                }
            }
            mix.withUnsafeBufferPointer { p in
                var start = 0
                while start < n {
                    let len = min(samplesPerBucket, n - start)
                    var v: Float = 0
                    vDSP_rmsqv(p.baseAddress! + start, 1, &v, vDSP_Length(len))
                    rms.append(v)
                    start += len
                }
            }
        }

        guard !rms.isEmpty else { return nil }
        var peak: Float = 0
        vDSP_maxv(rms, 1, &peak, vDSP_Length(rms.count))
        guard peak > 0 else { return [UInt8](repeating: 0, count: rms.count) }
        var scale = 255 / peak
        vDSP_vsmul(rms, 1, &scale, &rms, 1, vDSP_Length(rms.count))
        return rms.map { UInt8(min(255, max(0, $0.rounded()))) }
    }
}
