#!/usr/bin/env python3
"""
optimize_model.py — smanji veličinu HTDemucs6sCore.mlpackage kvantizacijom SAMO
težina, uz zadržan fp32 račun (aktivacije). To je suprotno od fp16 računa koji
nam je ubio kvalitet — težine se kvantizuju, ali matematika ostaje fp32.

Pravi više varijanti i za svaku meri veličinu + SNR vs PyTorch referenca:
  - int8 linear (per-channel)   ~1/4 težina
  - palettizacija 6-bit / 4-bit  (lookup tabela)

Pokretanje:
    .venv/bin/python optimize_model.py
"""

import os
import shutil

import numpy as np
import torch
import coremltools as ct
import coremltools.optimize.coreml as cto

from convert_core import load_inner, CoreWrapper, SEGMENT_SECONDS

BASE = "HTDemucs6sCore.mlpackage"


def dirsize_mb(path):
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            total += os.path.getsize(os.path.join(root, f))
    return total / (1024 * 1024)


def snr_db(ref, est):
    ref = ref.flatten().astype(np.float64); est = est.flatten().astype(np.float64)
    n = np.sum((ref - est) ** 2); s = np.sum(ref ** 2)
    return float("inf") if n == 0 else 10 * np.log10(s / n)


def main():
    torch.backends.mha.set_fastpath_enabled(False)
    torch.manual_seed(0)

    inner = load_inner()
    sr = inner.samplerate
    N = int(SEGMENT_SECONDS * sr)
    mix = torch.randn(1, 2, N)
    with torch.no_grad():
        z = inner._spec(mix)
        mag = inner._magnitude(z)
        spec_pt, time_pt = CoreWrapper(inner).eval()(mag, mix)
    feed = {"mag": mag.numpy(), "mix": mix.numpy()}

    def evaluate(path, label):
        ml = ct.models.MLModel(path, compute_units=ct.ComputeUnit.CPU_AND_GPU)
        out = ml.predict(feed)
        bs = {tuple(v.shape): v for v in out.values()}
        sc = bs[tuple(spec_pt.shape)]; tc = bs[tuple(time_pt.shape)]
        print(f"  [{label:16s}] {dirsize_mb(path):6.1f} MB  | "
              f"spec {snr_db(spec_pt.numpy(), sc):6.1f} dB | "
              f"time {snr_db(time_pt.numpy(), tc):6.1f} dB")

    base = ct.models.MLModel(BASE)
    print("Polazni fp32:")
    evaluate(BASE, "fp32 baseline")

    variants = [
        ("int8_linear", cto.OptimizationConfig(
            global_config=cto.OpLinearQuantizerConfig(
                mode="linear_symmetric", dtype="int8", granularity="per_channel")),
         cto.linear_quantize_weights),
        ("palette_6bit", cto.OptimizationConfig(
            global_config=cto.OpPalettizerConfig(nbits=6, mode="kmeans")),
         cto.palettize_weights),
        ("palette_4bit", cto.OptimizationConfig(
            global_config=cto.OpPalettizerConfig(nbits=4, mode="kmeans")),
         cto.palettize_weights),
    ]

    print("\nKvantizovane varijante (težine kvantizovane, račun ostaje fp32):")
    for name, cfg, fn in variants:
        out_path = f"HTDemucs6sCore_{name}.mlpackage"
        if os.path.exists(out_path):
            shutil.rmtree(out_path)
        m = fn(base, cfg)
        m.save(out_path)
        try:
            evaluate(out_path, name)
        except Exception as e:
            print(f"  [{name}] greška pri proveri: {e}")


if __name__ == "__main__":
    main()
