//
//  TempoDetector.swift
//  Mazut
//
//  Song tempo (BPM) estimate from the separated stems, fully on-device.
//
//  1. Mono signal at half rate (22.05 kHz) from the drums stem — the cleanest
//     view of the beat. Practically silent drums (ballads, acoustic) → the sum
//     of all stems instead (less reliable).
//  2. Onset envelope: log-compressed spectral flux, 512-sample Hann frames,
//     hop 128 (~172 frames/s), minus a 1 s moving average (so loudness changes
//     across the song don't bias the autocorrelation), half-wave rectified.
//  3. Autocorrelation of the envelope; each candidate BPM in 60…200 is scored
//     on the ACF at 1–4 beat periods (the multiples sharpen the estimate well
//     below one-frame resolution) and weighted by a log-normal prior around
//     120 BPM, which settles most double/half-tempo ambiguity. What it doesn't
//     settle, the user fixes with ×2 / ÷2 in the player. Plus a small bonus
//     for subdivisions (eighths / shuffle triplets) at the candidate tempo.
//  4. That whole-song value only picks the octave; the result is the median of
//     30 s windows searched within ±6 % of it, because songs played live drift
//     (AC/DC "Touch Too Much": whole-song ACF 121.5, windows/reference ≈ 123.8).
//
//  Checked on: clicks 72–140 BPM (quarters/eighths/shuffle) exact or ×2;
//  Touch Too Much 123.75 (ref 123–124); Parisienne Walkways 113.3 (= 2 × the
//  56.7 reference, a ÷2 case). Known miss: equal-strength eighths at 174 read
//  as 116 (2/3) — a −/+ fix, not ×2/÷2.
//
//  Everything per-sample/per-bin goes through vDSP/vForce: plain Swift loops
//  are ~50× slower in Debug (see CLAUDE.md). ~0.5 s for a 4-minute song.
//

import Foundation
import AVFoundation
import Accelerate

nonisolated enum TempoDetector {

    /// Bump when the algorithm changes so cached results get recomputed.
    static let version = 1

    static let searchRange: ClosedRange<Double> = 60...200

    /// Estimated tempo in BPM, or nil if the audio can't be read, is silent,
    /// or the calling task was cancelled (checked between the expensive steps).
    static func detect(stems: [StemKind: URL]) -> Double? {
        var signal: [Float]?
        var rate: Double = 0
        if let drums = stems[.drums], let (mono, sr) = readMono(drums) {
            var rms: Float = 0
            vDSP_rmsqv(mono, 1, &rms, vDSP_Length(mono.count))
            if rms > 0.003 { signal = mono; rate = sr }   // ≈ −50 dBFS
        }
        if signal == nil {
            // No usable drums: sum of all stems.
            var sum: [Float] = []
            for url in stems.values {
                if Task.isCancelled { return nil }
                guard let (mono, sr) = readMono(url) else { continue }
                if sum.isEmpty { sum = mono; rate = sr; continue }
                let n = min(sum.count, mono.count)
                sum.removeLast(sum.count - n)
                vDSP_vadd(sum, 1, mono, 1, &sum, 1, vDSP_Length(n))
            }
            signal = sum
        }
        guard let signal, !signal.isEmpty, rate > 0, !Task.isCancelled else { return nil }

        let hop = 128
        let env = onsetEnvelope(signal, hop: hop)
        guard env.count > 1000, !Task.isCancelled else { return nil }   // < ~6 s of audio
        let frameRate = rate / Double(hop)

        // Whole song: picks the octave (and is the answer for short songs).
        guard let global = bestTempo(env[...], frameRate: frameRate, range: searchRange)
        else { return nil }

        // Refine on 30 s windows (hop 15 s), searching only ±6 % around the
        // global value, and take the median. Played-live songs drift (an intro a
        // couple of BPM slower than the rest), which smears the whole-song ACF
        // and drags it off the tempo most of the song actually has.
        let win = Int(30 * frameRate), step = Int(15 * frameRate)
        let near = (global * 0.94)...(global * 1.06)
        var local: [Double] = []
        var start = 0
        while start + win <= env.count {
            if let t = bestTempo(env[start..<(start + win)], frameRate: frameRate,
                                 range: near, prior: false) {
                local.append(t)
            }
            start += step
        }
        guard local.count >= 3 else { return global }
        local.sort()
        return local[local.count / 2]
    }

    // MARK: - Audio

    /// File → mono at half the file's sample rate ((L+R)/2, pairs averaged).
    private static func readMono(_ url: URL) -> ([Float], Double)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let chunk: AVAudioFrameCount = 1 << 18
        guard file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
              let channels = buffer.floatChannelData else { return nil }

        var out = [Float]()
        out.reserveCapacity(Int(file.length / 2) + 1)
        var mixed = [Float](repeating: 0, count: Int(chunk))
        var half = [Float](repeating: 0, count: Int(chunk) / 2)
        let pairAverage: [Float] = [0.25, 0.25]   // × (L+R) → mean of 4 samples

        while file.framePosition < file.length {
            if Task.isCancelled { return nil }
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            let n = Int(buffer.frameLength) & ~1   // even (drops ≤1 sample per chunk)
            guard n > 0 else { break }
            if format.channelCount >= 2 {
                vDSP_vadd(channels[0], 1, channels[1], 1, &mixed, 1, vDSP_Length(n))
            } else {
                // Mono file: double it so the same 0.25 filter gives the mean.
                var two: Float = 2
                vDSP_vsmul(channels[0], 1, &two, &mixed, 1, vDSP_Length(n))
            }
            vDSP_desamp(mixed, 2, pairAverage, &half, vDSP_Length(n / 2), 2)
            out.append(contentsOf: half[0..<(n / 2)])
        }
        return out.isEmpty ? nil : (out, format.sampleRate / 2)
    }

    // MARK: - Onset envelope

    private static func onsetEnvelope(_ x: [Float], hop: Int) -> [Float] {
        let n = 512, log2n = vDSP_Length(9), bins = n / 2
        guard x.count > n, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        let frames = (x.count - n) / hop + 1
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        var windowed = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: bins)
        var im = [Float](repeating: 0, count: bins)
        var mag = [Float](repeating: 0, count: bins)
        var prev = [Float](repeating: 0, count: bins)
        var diff = [Float](repeating: 0, count: bins)
        var env = [Float](repeating: 0, count: frames)
        var compress: Float = 1000, one: Float = 1, zero: Float = 0
        var count = Int32(bins)

        x.withUnsafeBufferPointer { xp in
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    for f in 0..<frames {
                        vDSP_vmul(xp.baseAddress! + f * hop, 1, window, 1, &windowed, 1, vDSP_Length(n))
                        windowed.withUnsafeBufferPointer { wp in
                            wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) {
                                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(bins))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        // Packed Nyquist in imagp[0] — drop it, DC/Nyquist don't carry onsets.
                        ip[0] = 0
                        vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(bins))
                        // log(1 + C·|X|): compresses dynamics so quiet hits still count.
                        vDSP_vsmsa(mag, 1, &compress, &one, &mag, 1, vDSP_Length(bins))
                        vvlogf(&mag, mag, &count)
                        // Spectral flux: sum of positive bin increases.
                        vDSP_vsub(prev, 1, mag, 1, &diff, 1, vDSP_Length(bins))
                        vDSP_vthr(diff, 1, &zero, &diff, 1, vDSP_Length(bins))
                        var s: Float = 0
                        vDSP_sve(diff, 1, &s, vDSP_Length(bins))
                        env[f] = f == 0 ? 0 : s
                        swap(&prev, &mag)
                    }
                }
            }
        }

        // Subtract a ~1 s moving average (centred), keep the positive part.
        let w = min(171, frames | 1)
        guard frames > w else { return env }
        var sums = [Float](repeating: 0, count: frames - w + 1)
        vDSP_vswsum(env, 1, &sums, 1, vDSP_Length(sums.count), vDSP_Length(w))
        var invW = 1 / Float(w)
        vDSP_vsmul(sums, 1, &invW, &sums, 1, vDSP_Length(sums.count))
        var local = [Float](repeating: sums.first ?? 0, count: frames)
        local.replaceSubrange((w / 2)..<(w / 2 + sums.count), with: sums)
        if let last = sums.last {
            for i in (w / 2 + sums.count)..<frames { local[i] = last }
        }
        vDSP_vsub(local, 1, env, 1, &env, 1, vDSP_Length(frames))
        vDSP_vthr(env, 1, &zero, &env, 1, vDSP_Length(frames))

        // Light smoothing (~±12 ms triangle): onsets 1–2 frames wide would make
        // the ACF at fractional lags hit or miss depending on where the period
        // falls between frames (clean 140 BPM clicks read as 93 without it).
        let kernel: [Float] = [1, 2, 3, 2, 1].map { $0 / 9 }
        var padded = [Float](repeating: 0, count: frames + kernel.count - 1)
        padded.replaceSubrange(2..<(2 + frames), with: env)
        vDSP_conv(padded, 1, kernel, 1, &env, 1, vDSP_Length(frames), vDSP_Length(kernel.count))
        return env
    }

    // MARK: - Tempo from the envelope

    /// Best-scoring BPM in `range` for this stretch of onset envelope.
    /// `prior`: weight toward 120 BPM (octave choice) — off for the narrow refine.
    private static func bestTempo(_ env: ArraySlice<Float>, frameRate: Double,
                                  range: ClosedRange<Double>, prior: Bool = true) -> Double? {
        let beats = 4
        let maxLag = Int((frameRate * 60 / range.lowerBound) * Double(beats)) + 2
        guard env.count > maxLag * 2 else { return nil }

        // Unbiased autocorrelation, normalised to acf[0] = 1.
        var acf = [Double](repeating: 0, count: maxLag + 1)
        env.withUnsafeBufferPointer { e in
            for lag in 0...maxLag {
                var dot: Float = 0
                let len = env.count - lag
                vDSP_dotpr(e.baseAddress!, 1, e.baseAddress! + lag, 1, &dot, vDSP_Length(len))
                acf[lag] = Double(dot) / Double(len)
            }
        }
        guard acf[0] > 0 else { return nil }
        let a0 = acf[0]
        for i in acf.indices { acf[i] /= a0 }

        func acfAt(_ lag: Double) -> Double {
            let i = Int(lag)
            guard i + 1 < acf.count else { return 0 }
            let t = lag - Double(i)
            return acf[i] * (1 - t) + acf[i + 1] * t
        }

        var best: (bpm: Double, score: Double)?
        var bpm = range.lowerBound
        while bpm <= range.upperBound {
            let period = frameRate * 60 / bpm
            var score = 0.0
            for k in 1...beats { score += acfAt(period * Double(k)) }
            // Subdivision bonus (eighths or shuffle triplets between beats): the
            // true tempo has them, a 2/3- or 3/2-tempo impostor mostly doesn't —
            // without it a straight-eighths 174 BPM reads as 116.
            score += 0.5 * max(acfAt(period / 2), acfAt(period / 3))
            // Log-normal prior: 1 octave σ around 120 BPM.
            if prior {
                let octaves = log2(bpm / 120)
                score *= exp(-0.5 * octaves * octaves)
            }
            if score > (best?.score ?? -.infinity) { best = (bpm, score) }
            bpm += 0.05
        }
        guard let best, best.score > 0 else { return nil }
        return best.bpm
    }
}
