#!/usr/bin/env python3
"""
fp16_bisect.py — find which ops must stay fp32 so the fp16 model keeps its spec branch.

Background (2026-11, macOS 27.0.1): the shipped full-fp16 model measures spec 10 dB /
time 54 dB on CPU_AND_GPU (it was spec 57 / time 54 in 2026-06 with the identical file).
The fp32 graph is still fine (spec 120 / time 114), so the regression is fp16 numerics
in the spectral branch. This script converts variants that keep selected op TYPES in
fp32 and reports SNR + GPU latency for each.

    .venv/bin/python fp16_bisect.py                 # all variants
    .venv/bin/python fp16_bisect.py norm softmax    # only these
"""
import sys
import time
from collections import Counter

import numpy as np
import torch
import coremltools as ct

from convert_core import load_inner, CoreWrapper, SEGMENT_SECONDS

REDUCE = {"reduce_mean", "reduce_sum", "reduce_sum_square", "reduce_l2_norm"}
NORM_MATH = REDUCE | {"sqrt", "rsqrt", "pow", "real_div", "inverse"}
NORMS = {"layer_norm", "instance_norm", "batch_norm", "l2_norm"}

VARIANTS = {
    "fp16": set(),
    "reduce": REDUCE,
    "norm": NORM_MATH | NORMS,
    "softmax": {"softmax"},
    "norm+softmax": NORM_MATH | NORMS | {"softmax"},
    "norm+softmax+matmul": NORM_MATH | NORMS | {"softmax", "matmul"},
}


def snr_db(ref, est):
    ref = np.asarray(ref, np.float64).ravel(); est = np.asarray(est, np.float64).ravel()
    n = np.sum((ref - est) ** 2); s = np.sum(ref ** 2)
    return float("inf") if n == 0 else 10 * np.log10(s / n)


def main():
    torch.backends.mha.set_fastpath_enabled(False)
    torch.manual_seed(0)
    inner = load_inner()
    N = int(SEGMENT_SECONDS * inner.samplerate)
    mix = torch.randn(1, 2, N)
    with torch.no_grad():
        mag = inner._magnitude(inner._spec(mix))
        core = CoreWrapper(inner).eval()
        spec_pt, time_pt = core(mag, mix)
        traced = torch.jit.trace(core, (mag, mix), check_trace=False)
    feed = {"mag": mag.numpy(), "mix": mix.numpy()}

    wanted = sys.argv[1:] or list(VARIANTS)
    print(f"{'variant':22s} {'fp32 ops':>8s} {'spec':>7s} {'time':>7s} {'GPU ms':>7s}")
    for name in wanted:
        keep = VARIANTS[name]
        types = Counter()
        def selector(op, keep=keep):
            fp32 = op.op_type in keep
            if fp32: types[op.op_type] += 1
            return not fp32
        precision = (ct.precision.FLOAT16 if not keep
                     else ct.transform.FP16ComputePrecision(op_selector=selector))
        ml = ct.convert(
            traced,
            inputs=[ct.TensorType(name="mag", shape=mag.shape),
                    ct.TensorType(name="mix", shape=mix.shape)],
            outputs=[ct.TensorType(name="spec_out", dtype=np.float32),
                     ct.TensorType(name="time_out", dtype=np.float32)],
            compute_units=ct.ComputeUnit.CPU_AND_GPU,
            compute_precision=precision,
            minimum_deployment_target=ct.target.iOS18,
            convert_to="mlprogram",
        )
        out = ml.predict(feed)
        times = []
        for _ in range(3):
            t0 = time.perf_counter(); ml.predict(feed); times.append(time.perf_counter() - t0)
        print(f"{name:22s} {sum(types.values()):8d} {snr_db(spec_pt, out['spec_out']):7.1f} "
              f"{snr_db(time_pt, out['time_out']):7.1f} {min(times)*1000:7.0f}   {dict(types)}",
              flush=True)
        ml.save(f"HTDemucs6sCore_{name.replace('+', '_')}.mlpackage")


if __name__ == "__main__":
    main()
