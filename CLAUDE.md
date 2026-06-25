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

The Core ML model (`Mazut/HTDemucs6sCore.mlpackage`, weights ~142 MB) is committed via
**Git LFS**. After cloning without LFS: `git lfs install && git lfs pull`. Without the
model file the app throws `SeparationError.modelMissing` at separation time.

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

### Two known traps (do not regress)
- **Core ML output strides**: `time_out` is channel-stride-padded (343984, not 343980) for
  ×16 alignment. `consume()` in `DemucsSeparator` reads outputs via `.strides`, never
  assuming contiguity. Ignoring strides silently breaks the time branch (~2 dB) while the
  spectral branch still looks fine.
- **fp32 is mandatory** for the model. fp16 compute destroys the time branch (2.4 dB SNR =
  noise), so `computeUnits = .cpuAndGPU` (the ANE is fp16-only and is not used). Don't
  switch to fp16/all-compute-units to "speed it up."

## Regenerating the model (`conversion/`)

Only needed to rebuild `HTDemucs6sCore.mlpackage` from scratch; the app ships the LFS copy.
Pinned environment matters — coremltools 9.0 only supports up to torch 2.7, and numpy 2.x
breaks it:

```bash
cd conversion
python3.12 -m venv .venv
.venv/bin/python -m pip install torch==2.7.0 torchaudio==2.7.0 "numpy<2" demucs coremltools soundfile
.venv/bin/python convert_core.py     # → HTDemucs6sCore.mlpackage
.venv/bin/python verify_core.py      # numeric check vs PyTorch
```

Key scripts: `convert_core.py` (patches `_spec`/`_ispec` out, exports the real core;
needs `torch.backends.mha.set_fastpath_enabled(False)` and `compute_precision=FLOAT32`),
`verify_core.py` (SNR check), `optimize_model.py` (weight-only quantization; int8 ≈ 37 MB
was validated as good enough), `gen_fixture.py` + `*_dev.swift` (standalone macOS CLI that
validates the Swift DSP against PyTorch fixtures). Full findings and all numeric constants
are documented in `conversion/README.md` — read it before changing DSP or conversion code.
