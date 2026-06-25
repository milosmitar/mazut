#!/usr/bin/env python3
"""
convert_mixed.py — mixed-precision varijanta HTDemucs6sCore.

Cilj: težak deo (encoder + crosstransformer + spektralna grana) ide u fp16 →
može na ANE; osetljiva time grana (tencoder/tdecoder/_t) ostaje fp32. Ako time
SNR ostane visok (>~40 dB), vredi probati na uređaju sa computeUnits=.all.

Konvertuje i ODMAH meri SNR vs PyTorch core (spec + time), bez čuvanja u app.

    .venv/bin/python convert_mixed.py
    .venv/bin/python convert_mixed.py --fp32-also-transformer   # i transformer fp32

Selekcija je po IMENU MIL op-a (torch.jit.trace čuva scope → coremltools imenuje
op-ove po njemu). Skript ispiše koliko op-ova je zadržano u fp32 da vidimo da li
heuristika po imenu uopšte hvata time granu.
"""

import sys
import time

import numpy as np
import torch
import coremltools as ct

from convert_core import load_inner, CoreWrapper, SEGMENT_SECONDS

# Scope podstringovi čiji op-ovi ostaju fp32 (time grana).
FP32_SCOPES = ["tencoder", "tdecoder", "channel_upsampler_t", "channel_downsampler_t"]
if "--fp32-also-transformer" in sys.argv:
    FP32_SCOPES.append("crosstransformer")


def snr_db(ref, est):
    ref = ref.flatten().astype(np.float64)
    est = est.flatten().astype(np.float64)
    noise = np.sum((ref - est) ** 2)
    sig = np.sum(ref ** 2)
    return float("inf") if noise == 0 else 10 * np.log10(sig / noise)


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
        core = CoreWrapper(inner).eval()
        spec_pt, time_pt = core(mag, mix)

    print(f"→ trace ... (mag {tuple(mag.shape)}, mix {tuple(mix.shape)})")
    with torch.no_grad():
        traced = torch.jit.trace(core, (mag, mix), check_trace=False)

    # op_selector: True = pretvori u fp16, False = ostavi fp32.
    stats = {"fp16": 0, "fp32": 0}
    def op_selector(op):
        name = (op.name or "").lower()
        keep_fp32 = any(s in name for s in FP32_SCOPES)
        stats["fp32" if keep_fp32 else "fp16"] += 1
        return not keep_fp32

    full_fp16 = "--full-fp16" in sys.argv
    if full_fp16:
        precision = ct.precision.FLOAT16
        mode = "full-fp16"
    else:
        precision = ct.transform.FP16ComputePrecision(op_selector=op_selector)
        mode = "mixed"

    print(f"→ convert ({mode}: fp32 scopes = {[] if full_fp16 else FP32_SCOPES}) ...")
    t0 = time.time()
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="mag", shape=mag.shape),
            ct.TensorType(name="mix", shape=mix.shape),
        ],
        # I/O ostaje fp32 (Swift consume() čita Float32); SAMO interni račun je fp16.
        # Bez ovoga fp16 model daje Float16 izlaze → Swift čita kao Float32 → EXC_BAD_ACCESS.
        outputs=[ct.TensorType(name="spec_out", dtype=np.float32),
                 ct.TensorType(name="time_out", dtype=np.float32)],
        compute_units=ct.ComputeUnit.ALL,
        compute_precision=precision,
        minimum_deployment_target=ct.target.iOS18,
        convert_to="mlprogram",
    )
    if full_fp16:
        print(f"   convert {time.time()-t0:.0f}s | full fp16")
    else:
        print(f"   convert {time.time()-t0:.0f}s | op-ova: fp16={stats['fp16']} fp32={stats['fp32']}")

    out_path = "HTDemucs6sCore_fp16.mlpackage" if full_fp16 else "HTDemucs6sCore_mixed.mlpackage"
    mlmodel.save(out_path)

    # --- SNR vs PyTorch core ---
    out = mlmodel.predict({"mag": mag.numpy(), "mix": mix.numpy()})
    by_shape = {tuple(v.shape): v for v in out.values()}
    spec_cm = by_shape[tuple(spec_pt.shape)]
    time_cm = by_shape[tuple(time_pt.shape)]
    print("\n=== SNR (mixed Core ML vs PyTorch core) ===")
    print(f"  spec_out: {snr_db(spec_pt.numpy(), spec_cm):6.1f} dB")
    print(f"  time_out: {snr_db(time_pt.numpy(), time_cm):6.1f} dB   "
          f"(cilj >~40 dB; fp16-global je ovde bio ~2.4 dB)")
    print(f"\n✓ {out_path}")


if __name__ == "__main__":
    main()
