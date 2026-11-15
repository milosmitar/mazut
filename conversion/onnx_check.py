#!/usr/bin/env python3
"""
onnx_check.py — compare third-party htdemucs_6s ONNX exports (candidates for an
Android port via ONNX Runtime) against PyTorch, alongside our shipped Core ML model.

Models (download into --models-dir, default ~/.cache/mazut_onnx):
  stemsplit  htdemucs_6s_fp16weights.onnx            (StemSplitio/htdemucs-6s-onnx)
             mix -> stems; STFT/ISTFT INSIDE the graph (Conv1d DFT kernels).
  aw78       demucs_htdemucs_6s_s78_fp16w_ca.onnx    (Andremi/audioweb-models)
  aw39       demucs_htdemucs_6s_s39_fp16w_ca.onnx    (same, 3.9 s window)
             mix + spec -> freq (cac) + time; STFT/ISTFT OUTSIDE (like our Strategy B).
  coreml     ../Mazut/HTDemucs6sCore.mlpackage        (ours, .cpuAndGPU)

Two tests:
  1. Parity on one random segment vs PyTorch at the same window length (graph fidelity).
  2. A real song, chunked with overlap-add, per-stem SNR vs PyTorch at 7.8 s
     (end-to-end quality, including the cost of a shorter window), plus .wav files.

    .venv/bin/python onnx_check.py --song ~/Downloads/song.mp3 --seconds 60

Latency numbers are from this Mac, NOT from a phone — they only rank the models.
"""
import argparse
import os
import time
from fractions import Fraction

import numpy as np
import onnxruntime as ort
import soundfile as sf
import torch
import torchaudio

from convert_core import load_inner

HERE = os.path.dirname(os.path.abspath(__file__))
COREML_PATH = os.environ.get("MAZUT_COREML", os.path.join(HERE, "..", "Mazut", "HTDemucs6sCore.mlpackage"))
ONNX_FILES = {
    "stemsplit": "htdemucs_6s_fp16weights.onnx",
    "aw78": "demucs_htdemucs_6s_s78_fp16w_ca.onnx",
    "aw39": "demucs_htdemucs_6s_s39_fp16w_ca.onnx",
}
OVERLAP = 0.25


def snr_db(ref, est):
    ref = np.asarray(ref, np.float64).ravel(); est = np.asarray(est, np.float64).ravel()
    n = np.sum((ref - est) ** 2); s = np.sum(ref ** 2)
    return float("inf") if n == 0 else 10 * np.log10(s / n)


def set_segment(inner, seconds):
    inner.segment = Fraction(seconds).limit_denominator(100)


def make_runners(inner, models_dir, use_coreml):
    """name -> (window_len, fn(mix[1,2,L] torch) -> stems[6,2,L] torch)."""
    sr = inner.samplerate
    opts = ort.SessionOptions()
    opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    runners = {}

    for name, fname in ONNX_FILES.items():
        path = os.path.join(models_dir, fname)
        if not os.path.exists(path):
            print(f"  (skip {name}: {path} missing)")
            continue
        sess = ort.InferenceSession(path, opts, providers=["CPUExecutionProvider"])
        L = sess.get_inputs()[0].shape[-1]
        if name == "stemsplit":
            def fn(mix, sess=sess):
                return torch.from_numpy(sess.run(["stems"], {"mix": mix.numpy()})[0][0])
        else:
            def fn(mix, sess=sess, L=L):
                z = inner._spec(mix)
                feed = {"mix": mix.numpy(), "spec": torch.view_as_real(z).numpy()}
                freq, tim = sess.run(["freq", "time"], feed)
                x = inner._ispec(inner._mask(None, torch.from_numpy(freq)), L)
                return (x + torch.from_numpy(tim))[0]
        runners[name] = (L, fn)

    if use_coreml:
        import coremltools as ct
        ml = ct.models.MLModel(COREML_PATH, compute_units=ct.ComputeUnit.CPU_AND_GPU)
        L = int(7.8 * sr)

        def fn(mix):
            z = inner._spec(mix)
            o = ml.predict({"mag": inner._magnitude(z).numpy(), "mix": mix.numpy()})
            bs = {tuple(v.shape): torch.tensor(np.asarray(v)) for v in o.values()}
            x = inner._ispec(inner._mask(None, bs[(1, 6, 4, 2048, 336)]), L)
            return (x + bs[(1, 6, 2, L)])[0]
        runners["coreml"] = (L, fn)
    return runners


def torch_ref(inner, L):
    sr = inner.samplerate
    def fn(mix):
        set_segment(inner, L / sr)
        return inner(mix)[0]
    return fn


def parity(inner, runners):
    print("\n[1] Parity on a random segment vs PyTorch (same window), + latency on this Mac")
    print(f"  {'model':10s} {'window':>7s} {'min SNR':>9s} {'mean SNR':>9s} {'ms/seg':>8s} {'×RT':>6s}")
    sr = inner.samplerate
    for name, (L, fn) in runners.items():
        torch.manual_seed(0)
        mix = torch.randn(1, 2, L) * 0.1
        with torch.no_grad():
            ref = torch_ref(inner, L)(mix).numpy()
            fn(mix)  # warm-up
            t0 = time.perf_counter(); est = fn(mix).numpy(); dt = time.perf_counter() - t0
        snrs = [snr_db(ref[i], est[i]) for i in range(6)]
        print(f"  {name:10s} {L/sr:6.1f}s {min(snrs):8.1f}  {np.mean(snrs):8.1f}  "
              f"{dt*1000:8.0f} {L/sr/dt:6.1f}")


def load_song(path, sr, seconds):
    try:
        data, file_sr = sf.read(path, dtype="float32", always_2d=True)
        wav = torch.tensor(data.T)
    except Exception:
        wav, file_sr = torchaudio.load(path)
    if wav.shape[0] == 1: wav = wav.repeat(2, 1)
    wav = wav[:2]
    if file_sr != sr:
        wav = torchaudio.functional.resample(wav, file_sr, sr)
    if seconds:
        wav = wav[:, : int(seconds * sr)]
    return wav.contiguous()


def chunked(fn, wav, L):
    """Same overlap-add for every model, so only the model differs."""
    _, N = wav.shape
    stride = int(L * (1 - OVERLAP))
    win = torch.hann_window(L) + 1e-3
    out = torch.zeros(6, 2, N); wsum = torch.zeros(N); pos = 0
    while pos < N:
        chunk = wav[:, pos:pos + L]; n = chunk.shape[-1]
        if n < L: chunk = torch.nn.functional.pad(chunk, (0, L - n))
        with torch.no_grad():
            stems = fn(chunk[None])
        out[..., pos:pos + n] += stems[..., :n] * win[:n]
        wsum[pos:pos + n] += win[:n]; pos += stride
    return out / wsum.clamp(min=1e-6)


def song_test(inner, runners, song, seconds, out_dir):
    sr = inner.samplerate
    wav = load_song(song, sr, seconds)
    print(f"\n[2] Song: {os.path.basename(song)} ({wav.shape[-1]/sr:.1f}s), "
          f"per-stem SNR vs PyTorch @ 7.8 s")
    L78 = int(7.8 * sr)
    t0 = time.perf_counter()
    ref = chunked(torch_ref(inner, L78), wav, L78)
    print(f"  pytorch ref: {time.perf_counter()-t0:.1f}s")
    ests = {}
    for name, (L, fn) in runners.items():
        t0 = time.perf_counter()
        ests[name] = chunked(fn, wav, L)
        print(f"  {name}: {time.perf_counter()-t0:.1f}s")

    names = list(ests)
    print(f"\n  {'stem':8s} " + " ".join(f"{n:>10s}" for n in names))
    for i, stem in enumerate(inner.sources):
        print(f"  {stem:8s} " + " ".join(f"{snr_db(ref[i], ests[n][i]):10.1f}" for n in names))

    os.makedirs(out_dir, exist_ok=True)
    for i, stem in enumerate(inner.sources):
        sf.write(os.path.join(out_dir, f"pytorch_{stem}.wav"), ref[i].numpy().T, sr)
        for n in names:
            sf.write(os.path.join(out_dir, f"{n}_{stem}.wav"), ests[n][i].numpy().T, sr)
    print(f"\n  .wav files in {os.path.abspath(out_dir)}/")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models-dir", default=os.path.expanduser("~/.cache/mazut_onnx"))
    ap.add_argument("--song", help="audio file for the end-to-end test (optional)")
    ap.add_argument("--seconds", type=float, default=60, help="0 = whole song")
    ap.add_argument("--out", default=os.path.join(HERE, "listen_test", "onnx"))
    ap.add_argument("--no-coreml", action="store_true")
    args = ap.parse_args()

    torch.backends.mha.set_fastpath_enabled(False)
    inner = load_inner().eval()
    assert list(inner.sources) == ["drums", "bass", "other", "vocals", "guitar", "piano"]
    runners = make_runners(inner, args.models_dir, not args.no_coreml)
    parity(inner, runners)
    if args.song:
        song_test(inner, runners, args.song, args.seconds, args.out)


if __name__ == "__main__":
    main()
