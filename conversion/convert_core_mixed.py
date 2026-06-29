#!/usr/bin/env python3
"""
convert_core_mixed.py — C4: mixed-precision konverzija za Neural Engine.

Ideja: ANE radi samo fp16. Pun fp16 ruši TIME granu (README: 2.4 dB). Zato:
  - op-ove ISKLJUČIVO iz time grane (tdecoder + denormalizacija) → ostavi fp32
  - sve ostalo (enkoderi, crosstransformer, freq grana) → fp16 (ide na ANE)

Time-grana op-ove nalazimo reachability analizom MIL grafa: dostižni iz `time_out`
ali NE iz `spec_out`.

Konvertuje, pa odmah verifikuje SNR vs PyTorch core. Čuva u zaseban .mlpackage
da ne dira radni fp32 model.

    .venv/bin/python convert_core_mixed.py
"""

import sys
import time
import traceback

import numpy as np
import torch

import coremltools as ct
from convert_core import load_inner, CoreWrapper, SEGMENT_SECONDS

OUT_PATH = "HTDemucs6sCore_fp16mixed.mlpackage"


def snr_db(ref, est):
    ref = np.asarray(ref).flatten().astype(np.float64)
    est = np.asarray(est).flatten().astype(np.float64)
    noise = np.sum((ref - est) ** 2)
    sig = np.sum(ref ** 2)
    return float("inf") if noise == 0 else 10 * np.log10(sig / noise)


def collect_reachable(out_var):
    """Imena svih op-ova koji doprinose datom izlaznom Var-u (backward BFS)."""
    names, seen = set(), set()
    stack = [out_var.op] if out_var.op is not None else []
    while stack:
        op = stack.pop()
        if op is None or id(op) in seen:
            continue
        seen.add(id(op))
        names.add(op.name)
        for val in op.inputs.values():
            vs = val if isinstance(val, (list, tuple)) else [val]
            for v in vs:
                if hasattr(v, "op") and v.op is not None:
                    stack.append(v.op)
    return names


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
    print(f"→ mag {tuple(mag.shape)} | mix {tuple(mix.shape)}")

    print("→ torch.jit.trace ...")
    with torch.no_grad():
        traced = torch.jit.trace(core, (mag, mix), check_trace=False)

    inputs = [ct.TensorType(name="mag", shape=mag.shape),
              ct.TensorType(name="mix", shape=mix.shape)]
    outputs = [ct.TensorType(name="spec_out"), ct.TensorType(name="time_out")]

    # --- 1) MIL graf (fp32) za reachability ---
    print("→ MIL (milinternal) za reachability ...")
    t0 = time.time()
    prog = ct.convert(traced, inputs=inputs, outputs=outputs,
                      compute_precision=ct.precision.FLOAT32,
                      minimum_deployment_target=ct.target.iOS18,
                      convert_to="milinternal")
    print(f"   ({time.time()-t0:.0f}s)")
    fn = prog.functions["main"]
    outs = {o.name: o for o in fn.outputs}
    reach_time = collect_reachable(outs["time_out"])
    reach_spec = collect_reachable(outs["spec_out"])
    total_ops = sum(1 for _ in fn.operations)
    time_only = reach_time - reach_spec
    spec_only = reach_spec - reach_time
    shared = reach_time & reach_spec
    # op_type po imenu (za type-based selektore)
    type_by_name = {op.name: op.op_type for op in fn.operations}
    norm_types = {"layer_norm", "batch_norm", "instance_norm", "l2_norm", "rsqrt"}
    print(f"   ukupno {total_ops} | time-only {len(time_only)} | "
          f"spec-only {len(spec_only)} | shared {len(shared)}")

    # --- 2) Strategije: skup imena koja ostaju fp32 ---
    sym_diff = time_only | spec_only
    norm_names = {n for n, t in type_by_name.items() if t in norm_types}
    strategies = {
        "A time-only": time_only,
        "B oba-ekskluzivna": sym_diff,
        "C oba+norm": sym_diff | norm_names,
        "D oba+norm+shared-norm": sym_diff | norm_names,  # norm_names već uključuje shared
    }

    def convert_keep(keep_fp32):
        sel = lambda op: op.name not in keep_fp32      # True=fp16
        m = ct.convert(traced, inputs=inputs, outputs=outputs,
                       compute_units=ct.ComputeUnit.ALL,
                       compute_precision=ct.transform.FP16ComputePrecision(op_selector=sel),
                       minimum_deployment_target=ct.target.iOS18,
                       convert_to="mlprogram")
        o = m.predict({"mag": mag.numpy(), "mix": mix.numpy()})
        by_shape = {tuple(v.shape): v for v in o.values()}
        s = snr_db(spec_pt.numpy(), by_shape[tuple(spec_pt.shape)])
        t = snr_db(time_pt.numpy(), by_shape[tuple(time_pt.shape)])
        return m, s, t

    print("\n=== Mixed fp16 strategije (SNR vs PyTorch core, random šum) ===")
    print("    fp32(119/114) | pun fp16 time ~2.4 dB\n")
    results = {}
    for name, keep in strategies.items():
        if name.startswith("D"):   # D == C, preskoči duplikat
            continue
        t0 = time.time()
        m, s, t = convert_keep(keep)
        results[name] = (m, s, t, len(keep))
        print(f"  {name:24s} fp32 op {len(keep):4d}/{total_ops} | "
              f"spec {s:6.1f} | time {t:6.1f} dB  ({time.time()-t0:.0f}s)")

    # Sačuvaj najbolju po time SNR-u.
    best = max(results.items(), key=lambda kv: kv[1][2])
    best[1][0].save(OUT_PATH)
    print(f"\n✓ Najbolja ({best[0]}) sačuvana: {OUT_PATH}")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("\n" + "=" * 70)
        traceback.print_exc()
        print("=" * 70)
        sys.exit(1)
