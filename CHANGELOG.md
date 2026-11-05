# Changelog

All notable changes to this project are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions
follow [Semantic Versioning](https://semver.org/).

## 0.4.2 - 2026-11-05

### Fixed

- Builds on Windows again: `WaveData.prefetch` called `getpagesize()`, which Windows does not have (0.4.0's
  memory-mapped `SoundFont(url:)`). Windows maps no file — `SoundFont(url:)` reads it into memory there, as before —
  so the page size is only for the compiler.

## 0.4.1 - 2026-10-31

### Changed

- The per-sample loops (oscillator, filter, mix, reverb, chorus) run about 10× faster in unoptimized builds — 63
  voices with effects went from 127% to 12% of real time in a debug build on an M-series Mac — so an app's debug
  build can play back in real time. Release builds got faster too (2.2% → 1.2%). Rendered PCM is bit-identical, debug
  and release alike (see the README's "Performance in debug builds").

### Fixed

- `SoundFont(data:)` and `MidiFile(data:)` copied their bytes through a pointer that had escaped `withUnsafeBytes`.
  For a `Data` of up to 14 bytes (stored inline) that pointer is to a temporary copy, so optimized builds read garbage
  — which made 30 of the parsing tests fail under `swift test -c release` since 0.3.0. Real SoundFonts and MIDI files
  are larger and heap-backed, so they were not seen to be affected.

## 0.4.0 - 2026-10-31

### Added

- `Synthesizer.choke(key:on:)` fades a key's voices to silence within `Synthesizer.chokeReleaseTime` (50 ms) from
  their current level, ignoring the hold pedal — for cymbal chokes, whose SoundFont release a note-off cannot cut
  short. An extension beyond MeltySynth: streams that never call it render exactly as before (see the README's
  "Extensions beyond MeltySynth").

### Fixed

- The library builds for Android (swift.org 6.3.3 Android SDK): `Float` overloads of the libm functions the Android
  overlay lacks, and Bionic's non-optional `mmap` result.

## 0.3.0 - 2026-10-14

### Changed

- **Breaking:** `SoundFont.waveData` is a `WaveData` (a `RandomAccessCollection` of `Int16`) instead of `[Int16]`.
  `SoundFont(url:)` now reads the file through a read-only mapping and the sample pool in place, so only the samples
  voices actually play are paged in, and those pages are clean: they no longer count toward the process's memory
  footprint (a ~200 MB General MIDI font was ~200 MB of dirty memory for as long as it was loaded).
  `SoundFont(data:)` keeps its own copy as before, and no longer copies the pool a second time while parsing.
  Rendered PCM is bit-identical either way.

### Added

- `SoundFont.prefetchSamples(bank:patch:)` reads in the samples of the preset a channel set to that bank / patch
  plays, resolved exactly as a note resolves it, so a host can warm the instruments a score uses off the audio
  render thread before playback reaches them.
- `WaveData.isMemoryMapped`.

## 0.2.0 - 2026-07-22

### Added

- Optional SF2 note-on modulator support (`SynthesizerSettings.enableModulators`,
  default off) — resolves and applies note-on (velocity/key) modulators to
  attenuation, filter cutoff/Q, LFO/envelope→cutoff depths, pitch depths,
  coarse/fine/scale tune, mod-LFO→volume, pan, reverb/chorus sends, and the
  volume/modulation envelope times; off by default for MeltySynth parity.
