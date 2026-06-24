// istft_dev.swift — razvoj i verifikacija demucs ISTFT (_mask + _ispec) u Swiftu.
// Pokretanje:  swift istft_dev.swift
// Učitava fixtures/spec_out.bin → ISTFT → poredi sa fixtures/ispec.bin.

import Foundation
import Accelerate

let FIX = "fixtures"
let nFFT = 4096
let hop = 1024
let log2n = vDSP_Length(12)
let half = nFFT / 2           // 2048
let modelBins = 2048          // bins iz modela
let N = 343980
let stems = 6
let channels = 2
let le = Int(ceil(Double(N) / Double(hop)))   // 336
let framesIn = le + 4         // 340 (pad time 2 svake strane)
let olaLen = (framesIn - 1) * hop + nFFT       // 351232
let cropOffset = nFFT / 2 + hop / 2 * 3        // 2048 + 1536 = 3584

func loadFloats(_ p: String) -> [Float] {
    let d = try! Data(contentsOf: URL(fileURLWithPath: p))
    return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}
func optScaleSNR(_ ref: [Float], _ est: [Float]) -> (Double, Double) {
    var num = 0.0, den = 0.0
    for i in 0..<ref.count { num += Double(ref[i]) * Double(est[i]); den += Double(est[i]) * Double(est[i]) }
    let s = den == 0 ? 0 : num / den
    var noise = 0.0, sig = 0.0
    for i in 0..<ref.count { let d = Double(ref[i]) - s * Double(est[i]); noise += d * d; sig += Double(ref[i]) * Double(ref[i]) }
    return (s, noise == 0 ? .infinity : 10 * log10(sig / noise))
}

var hann = [Float](repeating: 0, count: nFFT)
for n in 0..<nFFT { hann[n] = 0.5 - 0.5 * cos(2 * Float.pi * Float(n) / Float(nFFT)) }
let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

// Jedan kanal: re/im [modelBins][le] (model izlaz) -> waveform [N]
func istftChannel(re: [[Float]], im: [[Float]], imagSign: Float, scale: Float) -> [Float] {
    var ola = [Float](repeating: 0, count: olaLen)
    var wsum = [Float](repeating: 0, count: olaLen)

    var realp = [Float](repeating: 0, count: half)
    var imagp = [Float](repeating: 0, count: half)
    var timeFrame = [Float](repeating: 0, count: nFFT)

    for f in 0..<framesIn {
        // _ispec: time pad 2 svake strane → frejmovi 2..2+le-1 nose podatke
        let dataT = f - 2
        for k in 0..<half { realp[k] = 0; imagp[k] = 0 }
        if dataT >= 0 && dataT < le {
            // bin 0 = DC; bins 1..2047; Nyquist (2048)=0 → imagp[0]=0
            realp[0] = re[0][dataT]
            for k in 1..<modelBins {
                realp[k] = re[k][dataT]
                imagp[k] = imagSign * im[k][dataT]
            }
        }
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                timeFrame.withUnsafeMutableBytes { raw in
                    let c = raw.bindMemory(to: DSPComplex.self).baseAddress!
                    vDSP_ztoc(&split, 1, c, 2, vDSP_Length(half))
                }
            }
        }
        let start = f * hop
        for i in 0..<nFFT {
            let w = hann[i]
            ola[start + i] += w * timeFrame[i] * scale
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

// ---- run ----
let specOut = loadFloats("\(FIX)/spec_out.bin")   // [6,4,2048,336]
let ispecRef = loadFloats("\(FIX)/ispec.bin")     // [6,2,N]
let T = le

func specIndex(_ s: Int, _ ch: Int, _ k: Int, _ t: Int) -> Int {
    return ((s * 4 + ch) * modelBins + k) * T + t
}

for imagSign in [Float(1.0), Float(-1.0)] {
    var est = [Float](repeating: 0, count: stems * channels * N)
    for s in 0..<stems {
        for c in 0..<channels {
            // cac: ch re = 2c, im = 2c+1
            var re = [[Float]](repeating: [Float](repeating: 0, count: T), count: modelBins)
            var im = [[Float]](repeating: [Float](repeating: 0, count: T), count: modelBins)
            for k in 0..<modelBins {
                for t in 0..<T {
                    re[k][t] = specOut[specIndex(s, 2 * c, k, t)]
                    im[k][t] = specOut[specIndex(s, 2 * c + 1, k, t)]
                }
            }
            let wav = istftChannel(re: re, im: im, imagSign: imagSign, scale: 1.0)
            for i in 0..<N { est[(s * channels + c) * N + i] = wav[i] }
        }
    }
    let (s, snr) = optScaleSNR(ispecRef, est)
    print("imagSign=\(imagSign):  optimalni scale=\(String(format: "%.5f", s))  SNR(@opt)=\(String(format: "%.1f", snr)) dB")
}
