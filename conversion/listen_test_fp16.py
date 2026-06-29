#!/usr/bin/env python3
"""
listen_test_fp16.py — A/B na PRAVOJ pesmi: fp32 ref vs int8 vs fp16mixed.

Isti chunker za sve (izoluje samo efekat preciznosti modela). Ispisuje per-stem
SNR i snima .wav za slušanje. Šum je pesimistično merenje — ovo je pošten broj.
"""

import os
import numpy as np
import soundfile as sf
import torch
import torchaudio
import coremltools as ct

from convert_core import load_inner

SONG = "/Users/itsuser/Downloads/G7 - Funky Blues 92bpm.wav"
OUT_DIR = "listen_test"
OVERLAP = 0.25
MODELS = {
    "int8": ("HTDemucs6sCore_int8_linear.mlpackage", ct.ComputeUnit.CPU_AND_GPU),
    "fp16mixed": ("HTDemucs6sCore_fp16mixed.mlpackage", ct.ComputeUnit.CPU_AND_GPU),
}


def snr_db(ref, est):
    ref = ref.flatten().astype(np.float64); est = est.flatten().astype(np.float64)
    n = np.sum((ref - est) ** 2); s = np.sum(ref ** 2)
    return float("inf") if n == 0 else 10 * np.log10(s / n)


def load_song(sr_target):
    data, sr = sf.read(SONG, dtype="float32", always_2d=True)
    wav = torch.tensor(data.T)
    if wav.shape[0] == 1: wav = wav.repeat(2, 1)
    elif wav.shape[0] > 2: wav = wav[:2]
    if sr != sr_target:
        wav = torchaudio.functional.resample(wav, sr, sr_target)
    return wav


def chunked(forward_fn, wav, TL):
    C, N = wav.shape
    stride = int(TL * (1 - OVERLAP))
    win = torch.hann_window(TL) + 1e-3
    out = torch.zeros(6, 2, N); wsum = torch.zeros(N); pos = 0
    while pos < N:
        chunk = wav[:, pos:pos + TL]; L = chunk.shape[-1]
        if L < TL: chunk = torch.nn.functional.pad(chunk, (0, TL - L))
        with torch.no_grad():
            stems = forward_fn(chunk[None])[0]
        out[..., pos:pos + L] += stems[..., :L] * win[:L]
        wsum[pos:pos + L] += win[:L]; pos += stride
    return out / wsum.clamp(min=1e-6)


def main():
    torch.backends.mha.set_fastpath_enabled(False)
    os.makedirs(OUT_DIR, exist_ok=True)
    inner = load_inner()
    sr = inner.samplerate
    TL = int(inner.segment * sr)
    wav = load_song(sr)
    print(f"→ Pesma: {wav.shape[-1]/sr:.1f}s @ {sr}Hz")

    def ml_forward(ml):
        def f(mix):
            z = inner._spec(mix); mag = inner._magnitude(z)
            o = ml.predict({"mag": mag.numpy(), "mix": mix.numpy()})
            bs = {tuple(v.shape): torch.tensor(v) for v in o.values()}
            spec_out = bs[(1, 6, 4, 2048, 336)]; time_out = bs[(1, 6, 2, TL)]
            return inner._ispec(inner._mask(None, spec_out), TL) + time_out
        return f

    print("→ fp32 referenca ...")
    ref = chunked(lambda m: inner(m), wav, TL)

    ests = {}
    for tag, (path, units) in MODELS.items():
        print(f"→ {tag} ...")
        ml = ct.models.MLModel(path, compute_units=units)
        ests[tag] = chunked(ml_forward(ml), wav, TL)

    print("\nPer-stem SNR vs fp32 (PRAVA muzika):")
    print(f"  {'stem':8s} " + "  ".join(f"{t:>9s}" for t in MODELS))
    for i, name in enumerate(inner.sources):
        row = "  ".join(f"{snr_db(ref[i].numpy(), ests[t][i].numpy()):9.1f}" for t in MODELS)
        print(f"  {name:8s} {row}")
        sf.write(f"{OUT_DIR}/fp32_{name}.wav", ref[i].numpy().T, sr)
        for t in MODELS:
            sf.write(f"{OUT_DIR}/{t}_{name}.wav", ests[t][i].numpy().T, sr)
    print(f"\n✓ .wav u {os.path.abspath(OUT_DIR)}/  (fp32_* vs int8_* vs fp16mixed_*)")


if __name__ == "__main__":
    main()
