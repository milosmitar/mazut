# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Mazut is an iOS/macOS SwiftUI app that separates a song into **6 stems** (drums, bass,
other, vocals, guitar, piano) **entirely on-device** by running Demucs v4 (`htdemucs_6s`)
through Core ML. No server, no network audio.

The repo has two halves:
- `Mazut/` — the shipping app (Swift).
- `conversion/` — Python + standalone-Swift scripts used to convert and verify the model. These are dev tooling, not part of the app build.

Note: code, comments, and UI strings are in Serbian. Match that when editing.

## Build & run

The app is an Xcode project with no package manager — open and build in Xcode:

```bash
open Mazut.xcodeproj
```

Targets iOS/macOS (deployment target 26.0, Swift 5.0, bundle id `com.tarmi.Mazut`).
There is no test target, no linter config, and no CI. "Verify" means run in the
simulator/device: pick a song → "Razdvoj pesmu" → listen to the 6 stems.

The Core ML model (`Mazut/HTDemucs6sCore.mlpackage`, **fp16 compute / fp32 I/O, weights
~72 MB**) is committed via **Git LFS**. After cloning without LFS: `git lfs install &&
git lfs pull`. Without the model file the app throws `SeparationError.modelMissing` at
separation time.

## Architecture: the "Strategy B" split

Core ML (MIL) cannot represent complex tensors, but `htdemucs` internally does
`torch.stft` → complex64 spectrograms. So the model was **cut**: STFT/ISTFT run in Swift
(vDSP/Accelerate), and only the real-valued neural core was converted to Core ML.

```
audio → [Swift STFT] → mag ─┐
                            ├─→ [Core ML core] → spec_out, time_out ─→ [Swift ISTFT + time] → 6 stems
audio (mix) ────────────────┘
```

Model I/O contract (must stay in sync with `DemucsDSP`/`DemucsSeparator`):
```
inputs:  mag [1,4,2048,336] (real cac spectrogram),  mix [1,2,343980]
outputs: spec_out [1,6,4,2048,336] (real cac),        time_out [1,6,2,343980]
stem[i] = ISTFT(view_as_complex(spec_out[:,i])) + time_out[:,i]
order:   drums, bass, other, vocals, guitar, piano   (== DemucsSeparator.modelOrder)
```

### Pipeline (app side)
1. `DemucsSeparator.separate(url:)` — orchestrates everything. Loads audio as 44.1 kHz
   stereo, chunks into 7.8 s segments (`segmentSamples = 343980`) with overlap-add, runs
   each segment, and writes 6 stem files. **GPU inference of segment `i` is overlapped
   with CPU ISTFT of `i-1` and STFT of `i+1`** — keep that pipelining intact when editing.
2. `DemucsDSP` — vDSP STFT (`magnitude`) and ISTFT (`istftChannel`), bit-matched to
   demucs `_spec`/`_ispec` (~132 dB SNR vs PyTorch). All numeric constants
   (`fwdScale = 1/128`, `invScale = 1/64`, pad/crop offsets, cac channel order
   `[L_re, L_im, R_re, R_im]`) are load-bearing — see `conversion/README.md` before
   touching them.
3. `StemCache` — persistent cache keyed by **SHA256 of the source file's content** under
   `<Application Support>/MazutStems/<hash>/`. Same song (any name/path) is separated only
   once. Stems stored as AAC `.m4a` (falls back to `.wav` for older caches).
4. `StemMixerEngine` — `AVAudioEngine` graph, one `AVAudioPlayerNode` per stem, synchronized
   transport (play/pause/seek) with per-stem volume/mute/solo.
5. `ContentView` — single SwiftUI view: library list, file importer, transport, stem mixer.

### Known traps (do not regress)
- **Core ML output strides**: `time_out` is channel-stride-padded (343984, not 343980) for
  ×16 alignment. `consume()` in `DemucsSeparator` reads outputs via `.strides`, never
  assuming contiguity. Ignoring strides silently breaks the time branch (~2 dB) while the
  spectral branch still looks fine.
- **Model I/O must stay fp32; do NOT enable the ANE.** The neural core uses **fp16 compute**
  (faster GPU) but **fp32 inputs/outputs**. If the model emits fp16 `spec_out`, the Swift
  `consume()` reads it as `Float` (4 B) and crashes (`EXC_BAD_ACCESS`) — `convert_mixed.py`
  forces fp32 outputs for this reason. Keep `computeUnits = .cpuAndGPU`: the ANE (`.all`)
  produces **garbage** for this model (spec −28 dB / time −1.6 dB), proven with both full-fp16
  and mixed precision — do not switch to `.all` to "speed it up." (fp16 *compute on GPU* is
  fine, ~54 dB; the old "fp16 destroys the time branch / fp32 is mandatory" note was from an
  older coremltools setup and no longer holds.)
- **`spec_out` is read strided in ISTFT** (`re[k*T+t]`, stride T). `consume()` copies it to a
  contiguous CPU buffer once (sequential memcpy) before ISTFT — keep that; it avoids strided
  access into GPU-backed Core ML output memory.

### Performance — profile in Release ONLY
Separation is **GPU-bound in Release**: ~720 ms/segment, ~22 s for a 3.5-min song
(~9.5× realtime) on iPhone 13 mini. The CPU side (per segment: STFT ~14 ms, ISTFT ~96 ms,
AAC write ~77 ms) hides behind GPU inference; `DemucsSeparator` logs a `[Mazut] profil/segment`
line (os_log, subsystem `com.tarmi.Mazut`) with the breakdown.

**Never profile/benchmark separation in Debug.** Swift `-Onone` inflates the vDSP DSP loops
(`DemucsDSP` STFT/ISTFT) ~50–60× (ISTFT 96 ms → ~5600 ms), making it falsely look
CPU/ISTFT-bound. The real bottleneck is the model, so speed work means model precision, not
the Swift DSP — which is already near the `.cpuAndGPU` ceiling.

## Regenerating the model (`conversion/`)

Only needed to rebuild `HTDemucs6sCore.mlpackage` from scratch; the app ships the LFS copy.
Pinned environment matters — coremltools 9.0 only supports up to torch 2.7, and numpy 2.x
breaks it. Python 3.9–3.12 all work (3.13 does not):

```bash
cd conversion
python3 -m venv .venv
.venv/bin/python -m pip install torch==2.7.0 torchaudio==2.7.0 "numpy<2" demucs coremltools soundfile certifi
# demucs downloads weights via torch.hub → needs SSL certs:
export SSL_CERT_FILE=$(.venv/bin/python -c "import certifi; print(certifi.where())")
.venv/bin/python convert_mixed.py --full-fp16   # → HTDemucs6sCore_fp16.mlpackage  (SHIPPED MODEL)
.venv/bin/python snr_check.py HTDemucs6sCore_fp16.mlpackage   # SNR per compute unit
```

The shipped model is **fp16** from `convert_mixed.py --full-fp16` (fp16 compute, fp32 I/O).
Copy it over `Mazut/HTDemucs6sCore.mlpackage` (it goes through Git LFS on commit).

Key scripts: `convert_core.py` (fp32 baseline; patches `_spec`/`_ispec` out, needs
`torch.backends.mha.set_fastpath_enabled(False)`), `convert_mixed.py` (fp16/mixed precision,
the shipped path), `snr_check.py` (SNR per compute unit — how the ANE-is-garbage finding was
made), `verify_core.py` (SNR vs PyTorch), `quantize_int8.py`/`optimize_model.py` (int8 weights,
37 MB — was shipped before fp16), `bench_istft.swift` (ISTFT microbenchmark; showed the DSP is
~12 ms on RAM, i.e. the device slowness was Debug `-Onone`), `gen_fixture.py` + `*_dev.swift`
(standalone macOS CLI validating the Swift DSP against PyTorch fixtures). Full findings and all
numeric constants are documented in `conversion/README.md` — read it before changing DSP or
conversion code.
