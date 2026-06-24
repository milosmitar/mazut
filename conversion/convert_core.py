#!/usr/bin/env python3
"""
convert_core.py — Strategija B.

Konvertuje SAMO realno jezgro htdemucs_6s u Core ML. STFT i ISTFT su izbačeni iz
modela (rade se u Swiftu / vDSP). Model:

  ulazi:
    mag : [1, 4, 2048, T]  realni cac spektrogram (real+imag kao kanali), T=336
    mix : [1, 2, N]        waveform (time grana), N = 343980 (7.8 s @ 44100)
  izlazi:
    spec_out : [1, 6, 4, 2048, T]  realni maskiran spektar (cac) → Swift radi ISTFT
    time_out : [1, 6, 2, N]        time grana → Swift sabira sa ISTFT izlazom

Konačni stem[i] = ISTFT(view_as_complex(spec_out[:,i])) + time_out[:,i]

Pokretanje:
    .venv/bin/python convert_core.py
"""

import math
import time
import traceback

import torch
import torch.nn as nn
from einops import rearrange

SEGMENT_SECONDS = 7.8
OUT_PATH = "HTDemucs6sCore.mlpackage"


def load_inner():
    from demucs.pretrained import get_model
    bag = get_model("htdemucs_6s")
    inner = bag.models[0]
    inner.eval()
    return inner


class CoreWrapper(nn.Module):
    """htdemucs.forward bez STFT/ISTFT — sve operacije su realne."""
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, mag, mix):
        m = self.model
        x = mag
        B, C, Fq, T = x.shape

        # Normalizacija freq grane (isto kao original).
        mean = x.mean(dim=(1, 2, 3), keepdim=True)
        std = x.std(dim=(1, 2, 3), keepdim=True)
        x = (x - mean) / (1e-5 + std)

        # Time grana.
        xt = mix
        meant = xt.mean(dim=(1, 2), keepdim=True)
        stdt = xt.std(dim=(1, 2), keepdim=True)
        xt = (xt - meant) / (1e-5 + stdt)

        saved, saved_t, lengths, lengths_t = [], [], [], []
        for idx, encode in enumerate(m.encoder):
            lengths.append(x.shape[-1])
            inject = None
            if idx < len(m.tencoder):
                lengths_t.append(xt.shape[-1])
                tenc = m.tencoder[idx]
                xt = tenc(xt)
                if not tenc.empty:
                    saved_t.append(xt)
                else:
                    inject = xt
            x = encode(x, inject)
            if idx == 0 and m.freq_emb is not None:
                frs = torch.arange(x.shape[-2], device=x.device)
                emb = m.freq_emb(frs).t()[None, :, :, None].expand_as(x)
                x = x + m.freq_emb_scale * emb
            saved.append(x)

        if m.crosstransformer is not None:
            if m.bottom_channels:
                b, c, f, t = x.shape
                x = rearrange(x, "b c f t-> b c (f t)")
                x = m.channel_upsampler(x)
                x = rearrange(x, "b c (f t)-> b c f t", f=f)
                xt = m.channel_upsampler_t(xt)
            x, xt = m.crosstransformer(x, xt)
            if m.bottom_channels:
                x = rearrange(x, "b c f t-> b c (f t)")
                x = m.channel_downsampler(x)
                x = rearrange(x, "b c (f t)-> b c f t", f=f)
                xt = m.channel_downsampler_t(xt)

        for idx, decode in enumerate(m.decoder):
            skip = saved.pop(-1)
            x, pre = decode(x, skip, lengths.pop(-1))
            offset = m.depth - len(m.tdecoder)
            if idx >= offset:
                tdec = m.tdecoder[idx - offset]
                length_t = lengths_t.pop(-1)
                if tdec.empty:
                    pre = pre[:, :, 0]
                    xt, _ = tdec(pre, None, length_t)
                else:
                    skip = saved_t.pop(-1)
                    xt, _ = tdec(xt, skip, length_t)

        S = len(m.sources)
        x = x.view(B, S, -1, Fq, T)
        x = x * std[:, None] + mean[:, None]       # spec_out (real cac)

        xt = xt.view(B, S, -1, mix.shape[-1])
        xt = xt * stdt[:, None] + meant[:, None]   # time_out
        return x, xt


def main():
    # Ugasi fuzovani MHA fast-path → attention se razlaže na matmul+softmax
    # (coremltools ne podržava _native_multi_head_attention).
    torch.backends.mha.set_fastpath_enabled(False)

    inner = load_inner()
    sr = inner.samplerate
    n_samples = int(SEGMENT_SECONDS * sr)
    mix = torch.randn(1, 2, n_samples)

    # Napravi realni mag ulaz preko pravih _spec/_magnitude (van modela).
    with torch.no_grad():
        z = inner._spec(mix)
        mag = inner._magnitude(z)
    print(f"→ mag ulaz: {tuple(mag.shape)} | mix ulaz: {tuple(mix.shape)}")

    core = CoreWrapper(inner).eval()
    with torch.no_grad():
        t0 = time.time()
        spec_out, time_out = core(mag, mix)
        print(f"→ core forward (CPU): {time.time()-t0:.1f}s")
        print(f"   spec_out: {tuple(spec_out.shape)} | time_out: {tuple(time_out.shape)}")

    print("→ torch.jit.trace ...")
    with torch.no_grad():
        traced = torch.jit.trace(core, (mag, mix), check_trace=False)

    print("→ coremltools.convert (FLOAT32 preciznost) ...")
    import coremltools as ct
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="mag", shape=mag.shape),
            ct.TensorType(name="mix", shape=mix.shape),
        ],
        outputs=[
            ct.TensorType(name="spec_out"),
            ct.TensorType(name="time_out"),
        ],
        compute_units=ct.ComputeUnit.CPU_AND_GPU,
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.iOS18,
        convert_to="mlprogram",
    )
    mlmodel.save(OUT_PATH)
    print(f"✓ Sačuvano: {OUT_PATH}")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("\n" + "=" * 70)
        traceback.print_exc()
        print("=" * 70)
        raise
