# Changelog

All notable changes to this project are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions
follow [Semantic Versioning](https://semver.org/).

## Unreleased

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
