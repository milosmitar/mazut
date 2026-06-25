#!/usr/bin/env python3
"""
quantize_int8.py — kvantizuj POSTOJEĆI HTDemucs6sCore.mlpackage na int8 (samo
težine, račun ostaje fp32), bez torch/demucs reference. Kvalitet je već validiran
u README-u (int8 ~37 MB, dovoljno dobro). Ovde samo proizvodimo model.

    .venv/bin/python quantize_int8.py  ../Mazut/HTDemucs6sCore.mlpackage  out.mlpackage
"""
import sys
import os
import coremltools as ct
import coremltools.optimize.coreml as cto


def dirsize_mb(path):
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            total += os.path.getsize(os.path.join(root, f))
    return total / (1024 * 1024)


def main():
    src, dst = sys.argv[1], sys.argv[2]
    print(f"Učitavam {src} ({dirsize_mb(src):.1f} MB)…")
    base = ct.models.MLModel(src)
    cfg = cto.OptimizationConfig(
        global_config=cto.OpLinearQuantizerConfig(
            mode="linear_symmetric", dtype="int8", granularity="per_channel"))
    print("Kvantizujem (int8 linear, per_channel, symmetric)…")
    m = cto.linear_quantize_weights(base, cfg)
    if os.path.exists(dst):
        import shutil
        shutil.rmtree(dst)
    m.save(dst)
    print(f"Sačuvano {dst} ({dirsize_mb(dst):.1f} MB)")


if __name__ == "__main__":
    main()
