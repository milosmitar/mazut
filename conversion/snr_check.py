#!/usr/bin/env python3
"""
snr_check.py — učitaj dati .mlpackage pod raznim compute unit-ima i izmeri SNR
vs PyTorch core. Izoluje da li je problem u grafu (preciznost) ili u izvršavanju
na konkretnom čipu (ANE/GPU).

    .venv/bin/python snr_check.py HTDemucs6sCore_mixed.mlpackage
"""
import sys
import numpy as np
import torch
import coremltools as ct

from convert_core import load_inner, CoreWrapper, SEGMENT_SECONDS


def snr_db(ref, est):
    ref = ref.flatten().astype(np.float64); est = est.flatten().astype(np.float64)
    n = np.sum((ref - est) ** 2); s = np.sum(ref ** 2)
    return float("inf") if n == 0 else 10 * np.log10(s / n)


def main():
    path = sys.argv[1]
    torch.backends.mha.set_fastpath_enabled(False)
    torch.manual_seed(0)
    inner = load_inner()
    N = int(SEGMENT_SECONDS * inner.samplerate)
    mix = torch.randn(1, 2, N)
    with torch.no_grad():
        mag = inner._magnitude(inner._spec(mix))
        spec_pt, time_pt = CoreWrapper(inner).eval()(mag, mix)
    feed = {"mag": mag.numpy(), "mix": mix.numpy()}

    units = {
        "CPU_ONLY": ct.ComputeUnit.CPU_ONLY,
        "CPU_AND_GPU": ct.ComputeUnit.CPU_AND_GPU,
        "ALL (ANE)": ct.ComputeUnit.ALL,
    }
    print(f"Model: {path}")
    for label, u in units.items():
        try:
            ml = ct.models.MLModel(path, compute_units=u)
            out = ml.predict(feed)
            by_shape = {tuple(v.shape): v for v in out.values()}
            sc = by_shape[tuple(spec_pt.shape)]; tc = by_shape[tuple(time_pt.shape)]
            print(f"  [{label:14s}] spec {snr_db(spec_pt.numpy(), sc):7.1f} dB | "
                  f"time {snr_db(time_pt.numpy(), tc):7.1f} dB")
        except Exception as e:
            print(f"  [{label:14s}] greška: {e}")


if __name__ == "__main__":
    main()
