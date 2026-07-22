# Changelog

All notable changes to this project are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions
follow [Semantic Versioning](https://semver.org/).

## Unreleased

### Added

- Optional SF2 note-on modulator support (`SynthesizerSettings.enableModulators`,
  default off) — resolves and applies note-on (velocity/key) modulators to
  attenuation, filter cutoff/Q, LFO/envelope→cutoff depths, pitch depths,
  coarse/fine/scale tune, mod-LFO→volume, pan, reverb/chorus sends, and the
  volume/modulation envelope times; off by default for MeltySynth parity.
