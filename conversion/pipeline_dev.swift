// pipeline_dev.swift — end-to-end provera Swift integracije.
// STFT(mix) → Core ML core → ISTFT+time → poredi sa fixtures/stems.bin.
// Pokretanje:  swift pipeline_dev.swift
// (validira indeksiranje spec_out/time_out i cac mapiranje — DSP glue iz app-a.)

import Foundation
import Accelerate
import CoreML

let FIX = "fixtures"
let nFFT = 4096, hop = 1024, half = 2048, F = 2048, N = 343980
let log2n = vDSP_Length(12)
let T = Int(ceil(Double(N) / Double(hop)))      // 336
let stems = 6, channels = 2
let fwdScale = Float(1.0 / (2.0 * sqrt(4096.0)))
let invScale = Float(1.0 / sqrt(4096.0))

func loadFloats(_ p: String) -> [Float] {
    let d = try! Data(contentsOf: URL(fileURLWithPath: p))
    return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}
func snr(_ ref: [Float], _ est: [Float]) -> Double {
    var no = 0.0, si = 0.0
    for i in 0..<ref.count { let d = Double(ref[i]) - Double(est[i]); no += d*d; si += Double(ref[i])*Double(ref[i]) }
    return no == 0 ? .infinity : 10*log10(si/no)
}
var hann = [Float](repeating: 0, count: nFFT)
for n in 0..<nFFT { hann[n] = 0.5 - 0.5*cos(2*Float.pi*Float(n)/Float(nFFT)) }
let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
func reflectPad(_ x: [Float], _ l: Int, _ r: Int) -> [Float] {
    var o = [Float](); o.reserveCapacity(x.count+l+r)
    for j in 0..<l { o.append(x[l-j]) }; o.append(contentsOf: x)
    for k in 0..<r { o.append(x[x.count-2-k]) }; return o
}
func magnitude(_ mix: [[Float]]) -> [Float] {
    var mag = [Float](repeating: 0, count: 4*F*T)
    var win = [Float](repeating: 0, count: nFFT)
    var rp = [Float](repeating: 0, count: half), ip = [Float](repeating: 0, count: half)
    for c in 0..<channels {
        let sp = reflectPad(mix[c], 1536, 1620)
        let ce = reflectPad(sp, 2048, 2048)
        let tot = 1 + sp.count/hop
        let cr = c*2, ci = c*2+1
        for f in 0..<tot {
            let dt = f-2; if dt < 0 || dt >= T { continue }
            vDSP_vmul(Array(ce[f*hop..<f*hop+nFFT]), 1, hann, 1, &win, 1, vDSP_Length(nFFT))
            rp.withUnsafeMutableBufferPointer { r in ip.withUnsafeMutableBufferPointer { im in
                var s = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
                win.withUnsafeBytes { vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &s, 1, vDSP_Length(half)) }
                vDSP_fft_zrip(setup, &s, 1, log2n, FFTDirection(FFT_FORWARD))
                mag[(cr*F+0)*T+dt] = r[0]*fwdScale; mag[(ci*F+0)*T+dt] = 0
                for k in 1..<F { mag[(cr*F+k)*T+dt] = r[k]*fwdScale; mag[(ci*F+k)*T+dt] = im[k]*fwdScale }
            }}
        }
    }
    return mag
}
func istftCh(_ re: UnsafePointer<Float>, _ im: UnsafePointer<Float>) -> [Float] {
    let framesIn = T+4, olaLen = (framesIn-1)*hop+nFFT, crop = 2048+1536
    var ola = [Float](repeating: 0, count: olaLen), ws = [Float](repeating: 0, count: olaLen)
    var rp = [Float](repeating: 0, count: half), ip = [Float](repeating: 0, count: half)
    var tf = [Float](repeating: 0, count: nFFT)
    for f in 0..<framesIn {
        let dt = f-2; for k in 0..<half { rp[k]=0; ip[k]=0 }
        if dt >= 0 && dt < T { rp[0]=re[0*T+dt]; for k in 1..<F { rp[k]=re[k*T+dt]; ip[k]=im[k*T+dt] } }
        rp.withUnsafeMutableBufferPointer { r in ip.withUnsafeMutableBufferPointer { imm in
            var s = DSPSplitComplex(realp: r.baseAddress!, imagp: imm.baseAddress!)
            vDSP_fft_zrip(setup, &s, 1, log2n, FFTDirection(FFT_INVERSE))
            tf.withUnsafeMutableBytes { vDSP_ztoc(&s, 1, $0.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(half)) }
        }}
        for i in 0..<nFFT { ola[f*hop+i] += hann[i]*tf[i]*invScale; ws[f*hop+i] += hann[i]*hann[i] }
    }
    var out = [Float](repeating: 0, count: N)
    for i in 0..<N { let w = ws[crop+i]; out[i] = w > 1e-8 ? ola[crop+i]/w : 0 }
    return out
}

// ---- load model + run ----
let mixFlat = loadFloats("\(FIX)/mix.bin")
var mix = [[Float]](repeating: [], count: 2)
for c in 0..<2 { mix[c] = Array(mixFlat[c*N..<(c+1)*N]) }
let stemsRef = loadFloats("\(FIX)/stems.bin")

let compiled = try MLModel.compileModel(at: URL(fileURLWithPath: "HTDemucs6sCore.mlpackage"))
let cfg = MLModelConfiguration(); cfg.computeUnits = .cpuAndGPU
let model = try MLModel(contentsOf: compiled, configuration: cfg)

let mag = magnitude(mix)
let magArr = try MLMultiArray(shape: [1,4,2048,336], dataType: .float32)
mag.withUnsafeBufferPointer { memcpy(magArr.dataPointer, $0.baseAddress!, mag.count*4) }
let mixArr = try MLMultiArray(shape: [1,2,NSNumber(value: N)], dataType: .float32)
let mp = mixArr.dataPointer.bindMemory(to: Float.self, capacity: 2*N)
for c in 0..<2 { for i in 0..<N { mp[c*N+i] = mix[c][i] } }

let input = try MLDictionaryFeatureProvider(dictionary: ["mag": magArr, "mix": mixArr])
let res = try model.prediction(from: input)
let spec = res.featureValue(for: "spec_out")!.multiArrayValue!
let time = res.featureValue(for: "time_out")!.multiArrayValue!
let specP = spec.dataPointer.bindMemory(to: Float.self, capacity: spec.strides[0].intValue)
let timeP = time.dataPointer.bindMemory(to: Float.self, capacity: time.strides[0].intValue)
let tStemStride = time.strides[1].intValue   // 687968 (padding!)
let tChStride = time.strides[2].intValue     // 343984

let ispecRefArr = loadFloats("\(FIX)/ispec.bin")     // [6,2,N]
let timeRefArr = loadFloats("\(FIX)/time_out.bin")   // [6,2,N]
var ispecSwift = [Float](repeating: 0, count: stems*channels*N)
var timeSwift = [Float](repeating: 0, count: stems*channels*N)
var est = [Float](repeating: 0, count: stems*channels*N)
for s in 0..<stems { for c in 0..<channels {
    let reOff = ((s*4+2*c)*F)*T, imOff = ((s*4+2*c+1)*F)*T
    let wav = istftCh(specP+reOff, specP+imOff)
    let tOff = s*tStemStride + c*tChStride
    for i in 0..<N {
        ispecSwift[(s*channels+c)*N+i] = wav[i]
        timeSwift[(s*channels+c)*N+i] = timeP[tOff+i]
        est[(s*channels+c)*N+i] = wav[i] + timeP[tOff+i]
    }
}}
print("Razlaganje po grani (SNR vs PyTorch):")
for s in 0..<stems {
    let rng = s*channels*N..<(s+1)*channels*N
    let iS = snr(Array(ispecRefArr[rng]), Array(ispecSwift[rng]))
    let tS = snr(Array(timeRefArr[rng]), Array(timeSwift[rng]))
    print("  stem \(s): ispec \(String(format: "%6.1f", iS)) dB | time \(String(format: "%6.1f", tS)) dB")
}

func dbfs(_ x: [Float]) -> Double {
    var s = 0.0; for v in x { s += Double(v)*Double(v) }
    return 10*log10(s/Double(x.count) + 1e-20)
}
let names = ["drums","bass","other","vocals","guitar","piano"]
print("End-to-end Swift pipeline vs PyTorch stems.bin:")
print("  stem      SNR     ref nivo   greška(apsolutno)")
for s in 0..<stems {
    let r = Array(stemsRef[s*channels*N..<(s+1)*channels*N])
    let e = Array(est[s*channels*N..<(s+1)*channels*N])
    var diff = [Float](repeating: 0, count: r.count)
    for i in 0..<r.count { diff[i] = r[i]-e[i] }
    print("  \(names[s].padding(toLength: 8, withPad: " ", startingAt: 0)): \(String(format: "%6.1f", snr(r, e))) dB  ref \(String(format: "%6.1f", dbfs(r)))dB  err \(String(format: "%6.1f", dbfs(diff)))dB")
}
