#!/usr/bin/env python3
"""
gen_fixture.py — referentni podaci za verifikaciju Swift STFT/pipeline-a.

Snima (raw little-endian float32) u fixtures/:
  mix.bin    [2, 343980]            determinističan ulazni signal (1 chunk)
  mag.bin    [4, 2048, 336]         očekivani _spec+_magnitude (cac) izlaz
  stems.bin  [6, 2, 343980]         očekivani fp32 stemovi (ceo pipeline, 1 chunk)
  meta.json  oblici + STFT parametri

Swift testovi učitavaju ove fajlove i porede (SNR).
"""
import json
import os

import numpy as np
import torch

from convert_core import load_inner, SEGMENT_SECONDS

OUT = "fixtures"


def make_signal(C, N):
    """Determinističan, 'muzički' signal: zbir tonova + chirp + malo šuma."""
    t = np.arange(N) / 44100.0
    sig = np.zeros((C, N), dtype=np.float32)
    freqs = [110.0, 220.0, 330.0, 440.0]
    for k, f in enumerate(freqs):
        sig += (0.2 / (k + 1)) * np.sin(2 * np.pi * f * t)[None, :]
    chirp = 0.15 * np.sin(2 * np.pi * (200 + 50 * t) * t)
    sig += chirp[None, :]
    rng = np.random.default_rng(0)
    sig += 0.02 * rng.standard_normal((C, N)).astype(np.float32)
    # blago različit levi/desni kanal
    sig[1] *= 0.9
    return torch.tensor(sig)


def main():
    torch.backends.mha.set_fastpath_enabled(False)
    os.makedirs(OUT, exist_ok=True)

    inner = load_inner()
    sr = inner.samplerate
    N = int(SEGMENT_SECONDS * sr)
    from convert_core import CoreWrapper
    mix = make_signal(inner.audio_channels, N)[None]   # [1, C, N]
    TL = int(inner.segment * sr)

    with torch.no_grad():
        z = inner._spec(mix)
        mag = inner._magnitude(z)          # [1,4,2048,336]
        stems = inner(mix)                 # [1,6,2,N] fp32 referenca (ceo forward)
        # Core path izlazi (za izolovan ISTFT test):
        spec_out, time_out = CoreWrapper(inner).eval()(mag, mix)   # [1,6,4,F,T],[1,6,2,N]
        zout = inner._mask(None, spec_out)                          # kompleks
        ispec = inner._ispec(zout, TL)                              # [1,6,2,N] spektralna grana

    mix[0].numpy().astype("<f4").tofile(f"{OUT}/mix.bin")
    mag[0].numpy().astype("<f4").tofile(f"{OUT}/mag.bin")
    stems[0].numpy().astype("<f4").tofile(f"{OUT}/stems.bin")
    spec_out[0].numpy().astype("<f4").tofile(f"{OUT}/spec_out.bin")   # [6,4,2048,336]
    time_out[0].numpy().astype("<f4").tofile(f"{OUT}/time_out.bin")   # [6,2,N]
    ispec[0].numpy().astype("<f4").tofile(f"{OUT}/ispec.bin")         # [6,2,N]

    meta = {
        "mix_shape": list(mix.shape),
        "mag_shape": list(mag[0].shape),
        "stems_shape": list(stems[0].shape),
        "sources": inner.sources,
        "samplerate": sr,
        "n_fft": inner.nfft,
        "hop_length": inner.hop_length,
        "segment_samples": N,
        "freq_bins": mag.shape[-2],
        "frames": mag.shape[-1],
        "cac_channel_order": ["L_re", "L_im", "R_re", "R_im"],
        "stft": "normalized=True, center=True, hann(periodic), pad_mode=reflect",
        "spec_pad": "reflect (1536, 1536 + le*hop - N), le=ceil(N/hop); pa frame trim [2:2+le]",
    }
    with open(f"{OUT}/meta.json", "w") as f:
        json.dump(meta, f, indent=2)

    print("✓ fixtures snimljeni:")
    for k in ["mix", "mag", "stems"]:
        sz = os.path.getsize(f"{OUT}/{k}.bin") / 1e6
        print(f"   {k}.bin  {sz:.1f} MB")
    print(json.dumps(meta, indent=2))


if __name__ == "__main__":
    main()
