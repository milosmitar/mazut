// bench_istft.swift — izmeri brzinu 12-kanalnog ISTFT-a (kao consume) na običnoj
// RAM memoriji (kontinualan bafer). Cilj: utvrditi algoritamski pod. Ako je ovde
// brzo, onda je 6 s na uređaju → strided pristup GPU-backed Core ML izlazu.
//   swiftc -O bench_istft.swift -o /tmp/bench && /tmp/bench
import Foundation
import Accelerate

let F = 2048, T = 336, n = 4096, hop = 1024, half = 2048
let framesIn = T + 4
let olaLen = (framesIn - 1) * hop + n
let cropOffset = 2048 + 1536
let N = 343980

var hann = [Float](repeating: 0, count: n)
for i in 0..<n { hann[i] = 0.5 - 0.5 * cos(2 * Float.pi * Float(i) / Float(n)) }
let invScale: Float = 1.0 / 64.0
let setup = vDSP_create_fftsetup(vDSP_Length(12), FFTRadix(kFFTRadix2))!

// Trenutni algoritam (skalarni), čita re[k*T+t] strided iz kontinualnog bafera.
func istftChannel(re: UnsafePointer<Float>, im: UnsafePointer<Float>) -> [Float] {
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
            for k in 1..<F { realp[k] = re[k * T + dataT]; imagp[k] = im[k * T + dataT] }
        }
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(12), FFTDirection(FFT_INVERSE))
                timeFrame.withUnsafeMutableBytes { raw in
                    vDSP_ztoc(&split, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(half))
                }
            }
        }
        let start = f * hop
        for i in 0..<n { ola[start + i] += hann[i] * timeFrame[i] * invScale; wsum[start + i] += hann[i] * hann[i] }
    }
    var out = [Float](repeating: 0, count: N)
    for i in 0..<N { let w = wsum[cropOffset + i]; out[i] = w > 1e-8 ? ola[cropOffset + i] / w : 0 }
    return out
}

// Kontinualan spec bafer [6,4,2048,336] (kao Core ML spec_out, ali u RAM-u).
let specCount = 6 * 4 * F * T
var spec = [Float](repeating: 0, count: specCount)
for i in 0..<specCount { spec[i] = Float.random(in: -1...1) }
let stemStride = 4 * F * T, chStride = F * T

func consume() {
    var waves = [[Float]](repeating: [], count: 12)
    spec.withUnsafeBufferPointer { sp in
        let base = sp.baseAddress!
        waves.withUnsafeMutableBufferPointer { wbuf in
            DispatchQueue.concurrentPerform(iterations: 12) { j in
                let s = j / 2, c = j % 2
                let reOff = s * stemStride + (2 * c) * chStride
                let imOff = s * stemStride + (2 * c + 1) * chStride
                wbuf[j] = istftChannel(re: base + reOff, im: base + imOff)
            }
        }
    }
    _ = waves[0][0]
}

// Zagrej pa meri.
consume()
let iters = 5
let t0 = CFAbsoluteTimeGetCurrent()
for _ in 0..<iters { consume() }
let dt = (CFAbsoluteTimeGetCurrent() - t0) / Double(iters)
print(String(format: "consume() (12 kanala, kontinualna RAM): %.0f ms/segment", dt * 1000))
