# swift-meltysynth

A pure-Swift SF2 (SoundFont) synthesizer, ported from sinshu's
[MeltySynth](https://github.com/sinshu/meltysynth) (C#, MIT).

**Status: vertical-slice spike — all four gates green.**

| Gate | Result |
|------|--------|
| G1 loader equivalence | pass — exact ints/strings/counts, smpl SHA-256 match, derived floats ≤ 1e-6 vs rustysynth dump |
| G2 one-note PCM equivalence | pass — left: maxAbs 9.87e-08, worst-window RMS 1.43e-08, SNR 121.25 dB, zero-lag corr 0.99999999999955; right: maxAbs 9.13e-08, worst-window RMS 1.36e-08, SNR 121.17 dB, zero-lag corr 0.99999999999957 |
| G3 real-time safety | pass — ≥5 s live AVAudioSourceNode no-trap; zero malloc delta; p99 0.34% (1 note) / 2.19% (64 voices) of the 11.6 ms deadline |
| G4 hermetic + attributed | pass — gated suites skip without the fixture SF2; MIT LICENSE + NOTICE since the first commit |

## Spike scope

SF2 loader (full structural parse of GeneralUser GS) + one full-fidelity voice
(oscillator, volume/modulation envelopes, both LFOs, resonant low-pass) + a minimal
`Synthesizer` (bank 0 / preset 0, `noteOn`/`noteOff`/`render`, fixed 8-voice pool).
Reverb/chorus, multichannel, voice stealing, and the MIDI sequencer are the full port's
scope.

## Try it

```sh
swift run -c release MeltySynthSpike play <path-to.sf2>            # live C4 + timing histogram
swift run -c release MeltySynthSpike export <path-to.sf2> out.wav  # 5 s float32 WAV
swift test                                                          # gated suites need the reference SF2
```

## Attribution

A Swift port of [MeltySynth](https://github.com/sinshu/meltysynth) by sinshu (MIT).
Test vectors are generated from [rustysynth](https://github.com/sinshu/rustysynth)
via `Tools/oracle` (see `Tests/MeltySynthTests/Fixtures/README.md`). See `NOTICE` and
`LICENSE`.
