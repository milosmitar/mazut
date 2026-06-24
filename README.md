# Mazut

On-device separacija muzike na **6 stemova** (drums, bass, other, vocals, guitar,
piano) na iOS/macOS, pokretanjem **Demucs v4 (`htdemucs_6s`)** modela kroz Core ML.

Sve se izvršava lokalno na uređaju — bez servera i bez slanja audija na mrežu.

## Kako radi (Strategija B)

Core ML (MIL) ne podržava kompleksne tensore, a `htdemucs` interno radi
`torch.stft` → complex64 spektrogram. Zato je model presečen:

- **STFT / ISTFT** se rade u Swiftu (Accelerate / vDSP).
- U Core ML je konvertovano samo **realno neuronsko jezgro** (`HTDemucs6sCore`).

```
audio → [Swift STFT] → mag ─┐
                            ├─→ [Core ML core] → spec_out, time_out ─→ [Swift ISTFT + time] → 6 stemova
audio (mix) ────────────────┘
```

I/O ugovor modela, STFT parametri i numerička verifikacija su detaljno opisani u
[`conversion/README.md`](conversion/README.md).

## Struktura repozitorijuma

| Putanja | Opis |
|---------|------|
| `Mazut/` | iOS/macOS aplikacija (SwiftUI) |
| `Mazut/Separation/DemucsDSP.swift` | vDSP STFT/ISTFT |
| `Mazut/Separation/DemucsSeparator.swift` | chunking 7.8 s + overlap-add, Core ML wrapper |
| `Mazut/Audio/` | `Stem`, `StemMixerEngine` (reprodukcija/miks stemova) |
| `Mazut/HTDemucs6sCore.mlpackage` | bundlovani Core ML model (preko Git LFS) |
| `conversion/` | Python/Swift skripte za konverziju i verifikaciju modela |

## Model

- Ulaz: 44100 Hz, stereo, segment 7.8 s (343980 sample-ova).
- Izlaz: `drums, bass, other, vocals, guitar, piano` (taj redosled = `StemKind`).
- Bundlovani model je **fp32** (`compute_units = CPU_AND_GPU`; ANE je fp16-only,
  a fp16 računa ruši kvalitet vremenske grane). int8 varijanta (~37 MB) je
  validirana kao dovoljno dobra za bundlovanje — vidi `conversion/optimize_model.py`.

### Git LFS

Model (`weight.bin`, ~142 MB) je u repou preko **Git LFS**. Za klon sa modelom:

```bash
git lfs install
git clone https://github.com/milosmitar/mazut.git
```

Ako je `git-lfs` instaliran posle kloniranja: `git lfs pull`.

## Build

1. Otvoriti `Mazut.xcodeproj` u Xcode-u.
2. Build & run (iOS simulator/uređaj ili macOS).
3. Izabrati pesmu → „Razdvoj pesmu" → dobijaju se 6 stemova za reprodukciju/miks.

## Regenerisanje modela (opciono)

Ako želiš da sam izgradiš `.mlpackage` umesto LFS verzije:

```bash
cd conversion
python3.12 -m venv .venv
.venv/bin/python -m pip install torch==2.7.0 torchaudio==2.7.0 \
  "numpy<2" demucs coremltools soundfile
.venv/bin/python convert_core.py     # → HTDemucs6sCore.mlpackage
.venv/bin/python verify_core.py      # numerička provera vs PyTorch
```

Detalji okruženja (Python 3.12, torch 2.7, numpy<2) i svi nalazi su u
[`conversion/README.md`](conversion/README.md).

## Licenca / model

`htdemucs_6s` potiče iz [Demucs](https://github.com/facebookresearch/demucs)
projekta — proveriti njihove uslove korišćenja pre distribucije modela.
