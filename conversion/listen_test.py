#!/usr/bin/env python3
"""
listen_test.py — A/B slušni test: fp32 vs int8 na PRAVOJ pesmi.

Ista pesma se razdvaja na 6 stemova dva puta, ISTIM chunker-om (da izolujemo
samo efekat kvantizacije):
  - fp32: pravi htdemucs.forward (referenca)
  - int8: Core ML int8 model + eksterni STFT/ISTFT (naša Strategija B putanja)

Snima sve stemove kao .wav u listen_test/ i ispisuje per-stem SNR (int8 vs fp32)
na pravoj muzici — pošteniji broj od ~28 dB merenog na šumu.
"""

import os
import numpy as np
import soundfile as sf
import torch
import torchaudio
import coremltools as ct

from convert_core import load_inner, CoreWrapper, SEGMENT_SECONDS

SONG = "/Users/itsuser/Downloads/G7 - Funky Blues 92bpm.wav"
INT8_MODEL = "HTDemucs6sCore_int8_linear.mlpackage"
OUT_DIR = "listen_test"
OVERLAP = 0.25


def snr_db(ref, est):
    ref = ref.flatten().astype(np.float64); est = est.flatten().astype(np.float64)
    n = np.sum((ref - est) ** 2); s = np.sum(ref ** 2)
    return float("inf") if n == 0 else 10 * np.log10(s / n)


def load_song(sr_target):
    data, sr = sf.read(SONG, dtype="float32", always_2d=True)   # [N, C]
    wav = torch.tensor(data.T)                                  # [C, N]
    if wav.shape[0] == 1:
        wav = wav.repeat(2, 1)
    elif wav.shape[0] > 2:
        wav = wav[:2]
    if sr != sr_target:
        wav = torchaudio.functional.resample(wav, sr, sr_target)
    return wav  # [2, N]


def chunked_separate(forward_fn, wav, TL):
    """Isti overlap-add chunker za oba modela. forward_fn: [1,2,TL] -> [1,6,2,TL]."""
    C, N = wav.shape
    stride = int(TL * (1 - OVERLAP))
    win = torch.hann_window(TL) + 1e-3
    out = torch.zeros(6, 2, N)
    wsum = torch.zeros(N)
    pos = 0
    while pos < N:
        chunk = wav[:, pos:pos + TL]
        L = chunk.shape[-1]
        if L < TL:
            chunk = torch.nn.functional.pad(chunk, (0, TL - L))
        with torch.no_grad():
            stems = forward_fn(chunk[None])[0]                  # [6,2,TL]
        seg = stems[..., :L]
        out[..., pos:pos + L] += seg * win[:L]
        wsum[pos:pos + L] += win[:L]
        pos += stride
    out = out / wsum.clamp(min=1e-6)
    return out  # [6,2,N]


def main():
    torch.backends.mha.set_fastpath_enabled(False)
    os.makedirs(OUT_DIR, exist_ok=True)

    inner = load_inner()
    sr = inner.samplerate
    TL = int(inner.segment * sr)
    wav = load_song(sr)
    print(f"→ Pesma: {wav.shape[-1]/sr:.1f}s @ {sr}Hz, chunk={TL/sr:.1f}s")
    sf.write(f"{OUT_DIR}/_original.wav", wav.T.numpy(), sr)

    # fp32 referenca: pravi forward.
    def fp32_forward(mix):
        return inner(mix)

    # int8: Core ML + eksterni STFT/ISTFT.
    ml = ct.models.MLModel(INT8_MODEL, compute_units=ct.ComputeUnit.CPU_AND_GPU)

    def int8_forward(mix):
        z = inner._spec(mix)
        mag = inner._magnitude(z)
        out = ml.predict({"mag": mag.numpy(), "mix": mix.numpy()})
        bs = {tuple(v.shape): torch.tensor(v) for v in out.values()}
        spec_out = bs[(1, 6, 4, 2048, 336)]
        time_out = bs[(1, 6, 2, TL)]
        zout = inner._mask(None, spec_out)
        x = inner._ispec(zout, TL)
        return x + time_out

    print("→ fp32 separacija ...")
    stems_fp32 = chunked_separate(fp32_forward, wav, TL)
    print("→ int8 separacija ...")
    stems_int8 = chunked_separate(int8_forward, wav, TL)

    print("\nPer-stem SNR (int8 vs fp32) na PRAVOJ muzici:")
    for i, name in enumerate(inner.sources):
        ref = stems_fp32[i].numpy(); est = stems_int8[i].numpy()
        print(f"  {name:8s}: {snr_db(ref, est):6.1f} dB")
        sf.write(f"{OUT_DIR}/fp32_{name}.wav", ref.T, sr)
        sf.write(f"{OUT_DIR}/int8_{name}.wav", est.T, sr)

    print(f"\n✓ Fajlovi u {os.path.abspath(OUT_DIR)}/  (fp32_*.wav vs int8_*.wav)")


if __name__ == "__main__":
    main()
