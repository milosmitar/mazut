// stft_dev.swift — razvoj i verifikacija demucs STFT u Swiftu (Accelerate).
// Pokretanje:  swift stft_dev.swift
// Učitava fixtures/mix.bin i fixtures/mag.bin, računa mag, ispisuje SNR.

import Foundation
import Accelerate

let FIX = "fixtures"
let nFFT = 4096
let hop = 1024
let log2n = vDSP_Length(12)
let half = nFFT / 2            // 2048
let freqBins = 2048            // posle [..., :-1, :]
let N = 343980
let channels = 2
let le = Int(ceil(Double(N) / Double(hop)))   // 336
let frames = le                                // 336

// ---- pomoćno: učitavanje raw float32 ----
func loadFloats(_ path: String) -> [Float] {
    let data = try! Data(contentsOf: URL(fileURLWithPath: path))
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

func snrDB(_ ref: [Float], _ est: [Float]) -> Double {
    var noise = 0.0, sig = 0.0
    for i in 0..<ref.count {
        let d = Double(ref[i]) - Double(est[i])
        noise += d * d
        sig += Double(ref[i]) * Double(ref[i])
    }
    return noise == 0 ? .infinity : 10 * log10(sig / noise)
}

// ---- reflect pad (bez ivičnog elementa, kao torch) ----
func reflectPad(_ x: [Float], _ left: Int, _ right: Int) -> [Float] {
    var out = [Float]()
    out.reserveCapacity(x.count + left + right)
    for j in 0..<left { out.append(x[left - j]) }          // x[left], x[left-1], ... x[1]
    out.append(contentsOf: x)
    for k in 0..<right { out.append(x[x.count - 2 - k]) }  // x[len-2], x[len-3], ...
    return out
}

// ---- hann periodic ----
var hann = [Float](repeating: 0, count: nFFT)
for n in 0..<nFFT { hann[n] = 0.5 - 0.5 * cos(2 * Float.pi * Float(n) / Float(nFFT)) }

let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
let scale = Float(1.0 / (2.0 * sqrt(Double(nFFT))))   // vDSP /2 + normalized /sqrt(N)

// Vrati (re, im) za bins 0..<freqBins jednog frejma (dužine nFFT).
// imagSign: +1 ili -1 (konvencija znaka vDSP vs torch — biramo testom).
func frameFFT(_ frame: [Float], imagSign: Float) -> ([Float], [Float]) {
    var win = [Float](repeating: 0, count: nFFT)
    vDSP_vmul(frame, 1, hann, 1, &win, 1, vDSP_Length(nFFT))

    var realp = [Float](repeating: 0, count: half)
    var imagp = [Float](repeating: 0, count: half)
    var re = [Float](repeating: 0, count: freqBins)
    var im = [Float](repeating: 0, count: freqBins)

    realp.withUnsafeMutableBufferPointer { rp in
        imagp.withUnsafeMutableBufferPointer { ip in
            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            win.withUnsafeBytes { raw in
                let cplx = raw.bindMemory(to: DSPComplex.self).baseAddress!
                vDSP_ctoz(cplx, 2, &split, 1, vDSP_Length(half))
            }
            vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            // bin 0: DC u realp[0]; Nyquist u imagp[0] (njega ne koristimo).
            re[0] = rp[0] * scale
            im[0] = 0
            for k in 1..<freqBins {
                re[k] = rp[k] * scale
                im[k] = imagSign * ip[k] * scale
            }
        }
    }
    return (re, im)
}

// ---- glavna STFT: mix [C,N] -> mag [4, freqBins, frames] (cac) ----
func computeMag(_ mix: [[Float]], imagSign: Float) -> [Float] {
    // _spec padding
    let padL = hop / 2 * 3                      // 1536
    let padR = padL + le * hop - N              // 1536 + 84 = 1620
    // center pad
    let cpad = nFFT / 2                          // 2048

    var mag = [Float](repeating: 0, count: 4 * freqBins * frames)
    for c in 0..<channels {
        let specPadded = reflectPad(mix[c], padL, padR)        // 347136
        let centered = reflectPad(specPadded, cpad, cpad)      // 351232
        // 340 frejmova, pa trim [2:2+le]
        let totalFrames = 1 + (specPadded.count) / hop          // 340
        var zRe = [[Float]](repeating: [], count: totalFrames)
        var zIm = [[Float]](repeating: [], count: totalFrames)
        for f in 0..<totalFrames {
            let start = f * hop
            let frame = Array(centered[start..<start + nFFT])
            let (re, im) = frameFFT(frame, imagSign: imagSign)
            zRe[f] = re; zIm[f] = im
        }
        // trim frames [2:2+le], cac pakovanje
        // mag kanali: c==0 -> [0]=L_re,[1]=L_im ; c==1 -> [2]=R_re,[3]=R_im
        let chRe = c * 2
        let chIm = c * 2 + 1
        for t in 0..<frames {
            let fr = zRe[t + 2]
            let fi = zIm[t + 2]
            for k in 0..<freqBins {
                mag[(chRe * freqBins + k) * frames + t] = fr[k]
                mag[(chIm * freqBins + k) * frames + t] = fi[k]
            }
        }
    }
    return mag
}

// ---- run ----
let mixFlat = loadFloats("\(FIX)/mix.bin")          // [2, N]
let magRef = loadFloats("\(FIX)/mag.bin")           // [4, 2048, 336]
var mix = [[Float]](repeating: [], count: channels)
for c in 0..<channels { mix[c] = Array(mixFlat[c * N..<(c + 1) * N]) }

for sign in [Float(1.0), Float(-1.0)] {
    let mag = computeMag(mix, imagSign: sign)
    print("imagSign=\(sign):  mag SNR = \(String(format: "%.1f", snrDB(magRef, mag))) dB  (count \(mag.count) vs ref \(magRef.count))")
}
