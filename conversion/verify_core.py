#!/usr/bin/env python3
"""
verify_core.py — numerička provera Strategije B.

1) Core ML core  vs  PyTorch core (isti mag/mix ulaz) → da li konverzija valja.
2) Puna rekonstrukcija (STFT → core → ISTFT + time grana)  vs  originalni
   demucs htdemucs.forward(mix) → da li je eksterni-STFT pristup ispravan.

Ako oba prođu, Swift port treba samo da replicira spectro/ispectro.
"""

import numpy as np
import torch

from convert_core import load_inner, CoreWrapper, SEGMENT_SECONDS


def snr_db(ref, est):
    ref = ref.flatten().astype(np.float64)
    est = est.flatten().astype(np.float64)
    noise = np.sum((ref - est) ** 2)
    sig = np.sum(ref ** 2)
    if noise == 0:
        return float("inf")
    return 10 * np.log10(sig / noise)


def reconstruct(inner, spec_out, time_out, length):
    """spec_out [1,6,4,F,T] real (cac) + time_out [1,6,2,N] → stemovi [1,6,2,N]."""
    zout = inner._mask(None, spec_out)        # cac putanja → kompleks
    x = inner._ispec(zout, length)            # ISTFT
    return x + time_out


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

    # --- 1) Core ML vs PyTorch core ---
    import coremltools as ct
    ml = ct.models.MLModel("HTDemucs6sCore.mlpackage")
    out = ml.predict({"mag": mag.numpy(), "mix": mix.numpy()})
    # Core ML izlaz su flatten-ovani tuple → mapiraj po obliku.
    by_shape = {tuple(v.shape): v for v in out.values()}
    spec_cm = torch.tensor(by_shape[tuple(spec_pt.shape)])
    time_cm = torch.tensor(by_shape[tuple(time_pt.shape)])

    print("=== 1) Core ML core vs PyTorch core ===")
    print(f"  spec_out SNR: {snr_db(spec_pt.numpy(), spec_cm.numpy()):6.1f} dB"
          f"  | max |Δ| {float((spec_pt-spec_cm).abs().max()):.2e}")
    print(f"  time_out SNR: {snr_db(time_pt.numpy(), time_cm.numpy()):6.1f} dB"
          f"  | max |Δ| {float((time_pt-time_cm).abs().max()):.2e}")

    # --- 2) eksterni-STFT rekonstrukcija vs originalni demucs ---
    with torch.no_grad():
        training_length = int(inner.segment * sr)
        ref = inner(mix)                                   # originalni forward
        rec_pt = reconstruct(inner, spec_pt, time_pt, training_length)
        rec_cm = reconstruct(inner, spec_cm, time_cm, training_length)

    print("\n=== 2) Rekonstrukcija (STFT van modela) vs originalni demucs.forward ===")
    print(f"  PyTorch core путања SNR:  {snr_db(ref.numpy(), rec_pt.numpy()):6.1f} dB")
    print(f"  Core ML  core путања SNR: {snr_db(ref.numpy(), rec_cm.numpy()):6.1f} dB")
    print("\n  (>40 dB = praktično identično; ~20-30 dB ok za fp16/Core ML)")


if __name__ == "__main__":
    main()
