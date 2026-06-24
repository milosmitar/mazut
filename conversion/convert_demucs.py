#!/usr/bin/env python3
"""
convert_demucs.py — pokušaj konverzije htdemucs_6s (Demucs v4, 6 stemova)
u Core ML (.mlpackage).

Izlaz modela su 6 stemova redom: drums, bass, other, vocals, guitar, piano
(poklapa se sa StemKind u Mazut aplikaciji).

Cilj ovog koraka (korak 1 iz plana): izmeriti da li model uopšte legne na
Core ML, koliko je veliki i koliko je brz. Skripta NAMERNO prvo pokušava
punu konverziju i jasno prijavljuje gde pukne (najverovatnije torch.stft),
da bismo na osnovu greške izabrali strategiju.

Pokretanje (iz conversion/ foldera, sa aktivnim venv-om):
    .venv/bin/python convert_demucs.py
"""

import sys
import time
import traceback

import torch

SEGMENT_SECONDS = 7.8   # htdemucs podrazumevani segment
OUT_PATH = "HTDemucs6s.mlpackage"


def load_model():
    from demucs.pretrained import get_model
    print("→ Učitavam htdemucs_6s ...")
    model = get_model("htdemucs_6s")
    model.eval()

    # get_model može vratiti BagOfModels — uzmi prvi pravi model.
    inner = model
    if hasattr(model, "models") and len(model.models) > 0:
        inner = model.models[0]

    print(f"   sources: {model.sources}")
    print(f"   samplerate: {model.samplerate}, audio_channels: {model.audio_channels}")
    seg = getattr(inner, "segment", SEGMENT_SECONDS)
    print(f"   segment: {seg}s")
    return model, inner, model.samplerate


class DemucsWrapper(torch.nn.Module):
    """Tanak wrapper da trace dobije čist (mix) -> (stems) graf."""
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, mix):
        # mix: [batch, channels, samples]  ->  [batch, sources, channels, samples]
        return self.model(mix)


def main():
    model, inner, sr = load_model()
    # Wrap-uj UNUTRAŠNJI HTDemucs (bag.forward baca NotImplementedError).
    wrapper = DemucsWrapper(inner).eval()

    n_samples = int(SEGMENT_SECONDS * sr)
    example = torch.randn(1, 2, n_samples)
    print(f"→ Probni ulaz: {tuple(example.shape)} ({SEGMENT_SECONDS}s @ {sr}Hz)")

    # 1) Sanity: forward pass u PyTorch-u (i gruba izmera brzine na CPU-u).
    print("→ PyTorch forward (CPU) ...")
    t0 = time.time()
    with torch.no_grad():
        out = wrapper(example)
    print(f"   izlaz: {tuple(out.shape)}  |  PyTorch CPU: {time.time()-t0:.1f}s za {SEGMENT_SECONDS}s zvuka")

    # 2) JIT trace
    print("→ torch.jit.trace ...")
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example, check_trace=False)

    # 3) Core ML konverzija
    print("→ coremltools.convert (ovo je tačka gde htdemucs obično pukne na STFT) ...")
    import coremltools as ct
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="mix", shape=example.shape)],
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.iOS18,
        convert_to="mlprogram",
    )
    mlmodel.save(OUT_PATH)
    print(f"✓ Sačuvano: {OUT_PATH}")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print("\n" + "=" * 70)
        print("✗ KONVERZIJA PREKINUTA — evo tačnog razloga:")
        print("=" * 70)
        traceback.print_exc()
        print("=" * 70)
        msg = str(e).lower()
        if "stft" in msg or "fft" in msg or "rfft" in msg:
            print("\nDijagnoza: pukao je STFT/FFT — očekivano za htdemucs.")
            print("Strategija B: izbaciti STFT iz modela i raditi ga u Swiftu (vDSP),")
            print("a konvertovati samo neuronsko jezgro. Javi i krećemo na to.")
        sys.exit(1)
