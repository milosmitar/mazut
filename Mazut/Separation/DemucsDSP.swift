//
//  DemucsDSP.swift
//  Mazut
//
//  STFT / ISTFT koji bit-tačno prate demucs htdemucs `_spec`/`_ispec`.
//  Verifikovano protiv PyTorch reference na ~132 dB SNR (vidi conversion/).
//  Kompleksni STFT se radi ovde (vDSP) jer Core ML ne podržava kompleksne tensore.
//

import Foundation
import Accelerate

/// Fiksni parametri modela htdemucs_6s (segment 7.8 s @ 44100).
nonisolated enum DemucsParams {
    static let nFFT = 4096
    static let hop = 1024
    static let log2n = vDSP_Length(12)
    static let half = nFFT / 2            // 2048
    static let freqBins = 2048            // posle [..., :-1, :]
    static let sampleRate = 44100
    static let segmentSamples = 343980    // TL = int(7.8 * 44100)
    static let frames = 336               // le = ceil(N/hop)
    static let stems = 6
    static let channels = 2

    static let specPadL = 1536            // hop/2*3
    static let specPadR = 1620            // specPadL + frames*hop - segmentSamples
    static let centerPad = 2048           // nFFT/2

    static let fwdScale = Float(1.0 / (2.0 * 4096.0.squareRootValue))   // 1/128
    static let invScale = Float(1.0 / 4096.0.squareRootValue)           // 1/64 = 0.015625
}

private extension Double { var squareRootValue: Double { Foundation.sqrt(self) } }

/// vDSP-bazirani STFT/ISTFT. Drži FFT setup i hann prozor (kreirati jednom).
/// `nonisolated` — čiste funkcije (samo read-only `setup`/`hann`), bezbedne za
/// poziv iz pozadinskih niti (concurrentPerform / pipeline).
nonisolated final class DemucsDSP: @unchecked Sendable {
    private let setup: FFTSetup
    private let hann: [Float]
    private let P = DemucsParams.self

    init() {
        setup = vDSP_create_fftsetup(DemucsParams.log2n, FFTRadix(kFFTRadix2))!
        var w = [Float](repeating: 0, count: DemucsParams.nFFT)
        for n in 0..<DemucsParams.nFFT {
            w[n] = 0.5 - 0.5 * cos(2 * Float.pi * Float(n) / Float(DemucsParams.nFFT))
        }
        hann = w
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    // MARK: - reflect pad (bez ivičnog elementa, kao torch)

    private func reflectPad(_ x: [Float], _ left: Int, _ right: Int) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(x.count + left + right)
        for j in 0..<left { out.append(x[left - j]) }
        out.append(contentsOf: x)
        for k in 0..<right { out.append(x[x.count - 2 - k]) }
        return out
    }

    // MARK: - STFT: mix [C][N] (N=segmentSamples) -> mag flat [4 * 2048 * 336] (cac)

    /// Vraća realni cac spektrogram, layout [ch(4)][freq(2048)][frame(336)] flat,
    /// kanali: [L_re, L_im, R_re, R_im] — spreman za MLMultiArray [1,4,2048,336].
    func magnitude(mix: [[Float]]) -> [Float] {
        let F = P.freqBins, T = P.frames, n = P.nFFT, hop = P.hop, half = P.half
        var mag = [Float](repeating: 0, count: 4 * F * T)

        var win = [Float](repeating: 0, count: n)
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)

        for c in 0..<P.channels {
            let specPadded = reflectPad(mix[c], P.specPadL, P.specPadR)
            let centered = reflectPad(specPadded, P.centerPad, P.centerPad)
            let totalFrames = 1 + specPadded.count / hop          // 340
            let chRe = c * 2, chIm = c * 2 + 1

            for f in 0..<totalFrames {
                let dataT = f - 2                                 // trim [2:2+le]
                guard dataT >= 0 && dataT < T else { continue }
                let start = f * hop
                vDSP_vmul(Array(centered[start..<start + n]), 1, hann, 1, &win, 1, vDSP_Length(n))

                realp.withUnsafeMutableBufferPointer { rp in
                    imagp.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        win.withUnsafeBytes { raw in
                            vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                        }
                        vDSP_fft_zrip(setup, &split, 1, P.log2n, FFTDirection(FFT_FORWARD))
                        // bin 0 (DC) real; Nyquist (imagp[0]) se ne koristi.
                        mag[(chRe * F + 0) * T + dataT] = rp[0] * P.fwdScale
                        mag[(chIm * F + 0) * T + dataT] = 0
                        for k in 1..<F {
                            mag[(chRe * F + k) * T + dataT] = rp[k] * P.fwdScale
                            mag[(chIm * F + k) * T + dataT] = ip[k] * P.fwdScale
                        }
                    }
                }
            }
        }
        return mag
    }

    // MARK: - ISTFT: jedan kanal, re/im flat [freqBins*frames] (indeks k*T+t) -> [segmentSamples]

    /// `re`/`im` su ravni baferi dužine freqBins*frames, indeksirani `k * frames + t`
    /// (tako su kontinualni u spec_out MLMultiArray-u po kanalu → bez kopija).
    func istftChannel(re: UnsafePointer<Float>, im: UnsafePointer<Float>) -> [Float] {
        let F = P.freqBins, T = P.frames, n = P.nFFT, hop = P.hop, half = P.half
        let framesIn = T + 4
        let olaLen = (framesIn - 1) * hop + n
        let cropOffset = P.centerPad + P.specPadL                 // 3584
        let N = P.segmentSamples

        var ola = [Float](repeating: 0, count: olaLen)
        var wsum = [Float](repeating: 0, count: olaLen)
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var timeFrame = [Float](repeating: 0, count: n)

        for f in 0..<framesIn {
            let dataT = f - 2
            for k in 0..<half { realp[k] = 0; imagp[k] = 0 }
            if dataT >= 0 && dataT < T {
                realp[0] = re[0 * T + dataT]
                for k in 1..<F {
                    realp[k] = re[k * T + dataT]
                    imagp[k] = im[k * T + dataT]
                }
            }
            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, P.log2n, FFTDirection(FFT_INVERSE))
                    timeFrame.withUnsafeMutableBytes { raw in
                        vDSP_ztoc(&split, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(half))
                    }
                }
            }
            let start = f * hop
            for i in 0..<n {
                let w = hann[i]
                ola[start + i] += w * timeFrame[i] * P.invScale
                wsum[start + i] += w * w
            }
        }

        var out = [Float](repeating: 0, count: N)
        for i in 0..<N {
            let idx = cropOffset + i
            let w = wsum[idx]
            out[i] = w > 1e-8 ? ola[idx] / w : 0
        }
        return out
    }
}
