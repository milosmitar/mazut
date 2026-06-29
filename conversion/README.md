# Mazut — Demucs → Core ML konverzija

Konverzija modela **htdemucs_6s** (Demucs v4, 6 stemova) u Core ML, za on-device
separaciju u Mazut aplikaciji.

## Model

- `htdemucs_6s` izlaz: **`drums, bass, other, vocals, guitar, piano`** (potvrđeno)
- samplerate: **44100 Hz**, kanali: **2 (stereo)**
- segment: **7.8 s** (transformer zahteva fiksnu dužinu ulaza → 343980 sample-ova)

Redosled stemova se poklapa sa `StemKind` enum-om u aplikaciji.

## Setup

```bash
cd conversion
python3.12 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install torch demucs coremltools soundfile numpy
```

Napomena: instalirani torch 2.12 noviji je nego što coremltools 9.0 zvanično
podržava (do 2.7). Ako konverzija puca na nepoznatim op-ovima, spustiti torch
na 2.7.x.

## Pokretanje

```bash
.venv/bin/python convert_demucs.py
```

## Status / nalazi (korak 1 — feasibility)

### Okruženje koje radi za konverziju
- Python **3.12** (ne 3.13)
- **torch==2.7.0** + **torchaudio==2.7.0** (coremltools 9.0 testiran samo do torch 2.7)
- **numpy<2** (1.26.4) — numpy 2.x ruši coremltools na `int(x.val)` cast-u
- demucs 4.0.1, coremltools 9.0

### Performanse (ohrabrujuće)
- PyTorch forward na **CPU: ~2 s za 7.8 s** zvuka. Model je lak → na Neural Engine-u
  realno znatno brže. On-device separacija je izvodljiva.

### Prepreka: STFT / kompleksni tensori
Puna konverzija puca na op-u 103:

```
ValueError: slice_by_index ... got tensor[1,2,2049,340,complex64]
```

htdemucs interno radi `torch.stft` → **complex64** spektrogram. Core ML (MIL) ne
podržava kompleksne tensore. Sve PRE STFT-a se konvertuje čisto (prošlo 103 op-a).

### Zaključak → Strategija B
STFT/ISTFT izbaciti iz modela i raditi ih u Swiftu (Accelerate/vDSP), a u Core ML
konvertovati samo realno neuronsko jezgro:

1. Patch-ovati htdemucs `_spec`/`_ispec` da model PRIMA već izračunat realni
   spektrogram (cac: realni+imag kao 2 kanala) i waveform, umesto da sam radi stft.
2. Model izbacuje maskiran spektar (realan) → ISTFT u Swiftu → + time-branch izlaz.
3. Konvertovati taj „core" model (bez stft/istft) u Core ML.

Ovo je netrivijalan posao (zahteva razumevanje htdemucs internih funkcija), ali je
standardan put za on-device Demucs.

### ✓ Strategija B implementirana i validirana (Python strana)

- `convert_core.py` — konvertuje realno jezgro u `HTDemucs6sCore.mlpackage`.
  - `torch.backends.mha.set_fastpath_enabled(False)` (inače pukne na
    `_native_multi_head_attention`).
  - **`compute_precision=FLOAT32`** je OBAVEZNO. Default fp16 ruši kvalitet
    (time grana → 2.4 dB SNR = šum). fp32 → ne radi na Neural Engine-u (ANE je
    fp16-only), pa `compute_units=CPU_AND_GPU`. Za offline obradu ok.
- `verify_core.py` — numerička provera:
  - Core ML core vs PyTorch core: **spec 119 dB, time 114 dB**
  - Cela rekonstrukcija vs originalni `demucs.forward`: **121 dB** (≈ identično)
- Model: **142 MB** (fp32). fp16 bi bio 72 MB ali neupotrebljiv za ovaj model.

### I/O ugovor modela (za Swift)

```
ulazi:   mag [1,4,2048,336] (realni cac spektrogram),  mix [1,2,343980]
izlazi:  spec_out [1,6,4,2048,336] (realni cac),        time_out [1,6,2,343980]
stem[i] = ISTFT(view_as_complex(spec_out[:,i])) + time_out[:,i]
redosled: drums, bass, other, vocals, guitar, piano
```

### STFT parametri koje Swift (vDSP) mora verno replicirati

- `spectro`: `torch.stft(x, n_fft=4096, hop=1024, window=hann(4096), win_length=4096,
  normalized=True, center=True, return_complex=True, pad_mode='reflect')`
  → uzeti `[..., :-1, :]` (2049→2048 freq bina).
- `_spec` dodatni padding: `pad = 1536`; ulaz se reflect-paduje na
  `(pad, pad + le*hop - N)` gde `le = ceil(N/hop)`; pa frame trim `z[..., 2:2+le]`.
- `_magnitude` (cac): kompleks → realno, `view_as_real` + permute → 2*C kanala
  (stereo → 4 kanala: re_L, re_R, im_L, im_R po permute redosledu).
- `normalized=True` znači skaliranje sa `1/sqrt(n_fft)` — pažljivo uskladiti.
- `_ispec`: inverzno (F.pad freq +1 i time ±2, pa istft, pa trim na length).

### Optimizacija veličine (`optimize_model.py`)

Kvantizacija SAMO težina, račun ostaje fp32 (suprotno od fp16 računa koji je ubio kvalitet):

| Varijanta | Veličina | spec SNR | time SNR |
|-----------|----------|----------|----------|
| fp32 baseline | 142 MB | 119 dB | 114 dB |
| int8 linear (sym/asym) | ~37 MB | ~27-29 dB | ~24-29 dB |
| palette 8-bit | 37 MB | 29 dB | 24 dB |
| palette 6-bit | 28 MB | 16 dB | 16 dB |
| palette 4-bit | 19 MB | -0.5 dB | 5 dB |

Zaključak: prosta post-training kvantizacija staje na ~37 MB / ~28 dB. Za bolji
kompromis trebalo bi mixed-precision (osetljivi slojevi fp32) ili QAT (retrening).
SNR je meren na random šumu (pesimistično) — na pravoj muzici treba slušni test.
Alternativa: fp32 model hostovati i skinuti pri prvom pokretanju (bez app bloat-a).

### Slušni test na pravoj muzici (`listen_test.py`)

fp32 vs int8, ista pesma, isti chunker → izoluje efekat kvantizacije. Na pravoj
muzici int8 je znatno bolji nego što ~28 dB na šumu sugeriše:

- Prisutni instrumenti: drums ~32 dB, bass ~41 dB, guitar ~25 dB SNR — čisto.
- int8 dodaje konstantan šumni prag ~−55..−68 dBFS (apsolutno tiho).
- Prazni stemovi (nema vokala/klavira u pesmi) pokazuju „negativan SNR" jer je
  referenca tišina — ali leakage je na ~−68 dBFS, praktično nečujno.

→ Odluka: **int8 (37 MB) je dovoljno dobar za bundlovanje u app.**
Fajlovi za A/B: `conversion/listen_test/{fp32,int8}_<stem>.wav`.

### ✓ Swift DSP verifikovan (van Xcode-a, protiv fixtures)

`stft_dev.swift` i `istft_dev.swift` — razvijeni kao macOS CLI, provereni protiv
`fixtures/` (gen `gen_fixture.py`):

- **STFT** (mix → mag): **132 dB** SNR vs PyTorch `_spec`+`_magnitude`.
- **ISTFT** (spec_out → waveform): **132.7 dB** SNR vs PyTorch `_ispec`.

Ključne konstante (potvrđene):
- forward bins: `vDSP_fft_zrip` FORWARD, skala `1/(2·√nFFT) = 1/128`, imagSign **+1**.
- inverzni: `vDSP_fft_zrip` INVERSE, skala **`1/√nFFT = 1/64 = 0.015625`**, imagSign **+1**.
- reflect pad bez ivice; hann periodic; cac kanali [L_re, L_im, R_re, R_im].
- frame trim `[2:2+le]`; ISTFT crop offset `nFFT/2 + 1536 = 3584`, dužina N.

### ✓ App integracija — GOTOVO i verifikovano

1. ✓ `vDSP` STFT/ISTFT → `Mazut/Separation/DemucsDSP.swift`.
2. ✓ Chunking 7.8 s + overlap-add (hann, 0.25) → `DemucsSeparator.swift`.
3. ✓ Core ML wrapper: mag+mix → spec_out+time_out.
4. ✓ Dugme „Razdvoj pesmu" → 6 .wav → `StemMixerEngine`.
5. ✓ `HTDemucs6sCore.mlpackage` u app folderu (synchronized group, auto-bundle).

**End-to-end provera** (`pipeline_dev.swift`, STFT→CoreML→ISTFT+time vs `stems.bin`):
svi stemovi **81–124 dB**, greška na −140..−159 dBFS (ispod fp32 praga). Korektno.

### ⚠ Stride/padding zamka (Core ML izlazi)

Core ML MLMultiArray izlazi NISU nužno kontinualni. `time_out [1,6,2,343980]` ima
kanal-stride **343984** (padding na poravnanje ×16), ne 343980. `spec_out` jeste
kontinualan (336, 2048 deljivi sa 16). MORA se čitati preko `.strides`, inače je
time grana polomljena (~2 dB) dok spektralna izgleda ok — podmukao bug.

### ✓ fp16 model + ANE istraga + nalaz o brzini (2026-06)

Cilj je bila brzina. Redosled saznanja (sve mereno na iPhone 13 mini):

**1. Model precision (`convert_mixed.py`, `snr_check.py`).** SNR mixed/fp16 modela
vs PyTorch core, **po compute unit-u**:

| Compute unit | spec SNR | time SNR |
|--------------|----------|----------|
| CPU_ONLY     |  26.6 dB |  23.9 dB |
| **CPU_AND_GPU** | **57.4 dB** | **54.1 dB** |
| ALL (ANE)    | **−28 dB** | **−1.6 dB** |

- **fp16 na CPU_AND_GPU je odličan (54 dB)** — stari nalaz „fp16 ubija time granu
  (2.4 dB)" više NE važi (coremltools 9 + iOS18 drži fp16 akumulaciju u fp32 na GPU).
- **ANE (`.all`) daje smeće** — i sa punim fp16 i sa mixed-precision (fp32 ostrva).
  Pošto i čist fp16 puca na ANE, ni podela na dva modela ne bi pomogla. **ANE put je
  zatvoren za ovaj model.** Ostaje `computeUnits = .cpuAndGPU`.
- **fp16 model MORA imati fp32 izlaze** (`ct.TensorType(dtype=np.float32)`), inače Swift
  `consume()` čita Float16 kao Float32 → `EXC_BAD_ACCESS`. Interni račun ostaje fp16.
- Izabran **fp16** (72 MB) umesto int8 (37 MB): brži GPU (~720 vs ~1000 ms/seg) i bolji
  kvalitet (54 vs ~28 dB). int8 ostaje opcija ako je veličina app-a kritična.

**2. Profil i pravo usko grlo (`bench_istft.swift`).** U **Release**-u je obrada
**GPU-bound**: ~720 ms/seg, ~22 s za 3.5-min pesmu (~9.5× realtime). Po segmentu:
GPU ~720 ms | STFT ~14 ms | ISTFT ~96 ms | AAC upis ~77 ms.

> ⚠ **PROFILIŠI ISKLJUČIVO U RELEASE.** Swift `-Onone` (Debug) naduvava vDSP DSP petlje
> (STFT/ISTFT) **~50–60×** (ISTFT 96 ms → ~5600 ms), pa separacija lažno izgleda
> CPU/ISTFT-bound. `bench_istft.swift` (`-O`) pokazuje ISTFT ~12 ms na RAM-u → algoritam
> nije problem. Cela jedna istraga je potrošena jureći taj Debug artefakt.

**3. App-side popravke** (`DemucsSeparator`): kopija `spec_out` u kontinualni RAM pre
ISTFT-a (izbegava strided pristup GPU-backed izlazu), paralelni AAC upis 6 stemova,
razdvojeni profiling tajmeri.

### Preostalo / ideje za brzinu

- Već GPU-bound na `.cpuAndGPU`; dalja brzina znači sam model (ANE je mrtav).
- Eventualno: int8 težine + fp16 račun (37 MB + brz GPU) ako treba manji app.
