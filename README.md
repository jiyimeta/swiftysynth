# swiftysynth

A pure-Swift SF2 (SoundFont) synthesizer, ported from sinshu's
[MeltySynth](https://github.com/sinshu/meltysynth) (C#, MIT).

**Status: full port, Phase 0+1+2 complete — 16-channel synthesizer with
steal-to-play dynamic voice allocation (the AUMIDISynth fix) and the
Freeverb reverb + chorus effects bus. All prior gates plus G2-fx / G3-fx
green. MIDI file playback (P3) and API polish (P4) follow.**

| Gate | Result |
|------|--------|
| G1 loader equivalence | pass — exact ints/strings/counts, smpl SHA-256 match, derived floats ≤ 1e-6 vs rustysynth dump |
| G2 one-note PCM equivalence | pass — left: maxAbs 9.87e-08, worst-window RMS 1.43e-08, SNR 121.25 dB, zero-lag corr 0.99999999999955; right: maxAbs 9.13e-08, worst-window RMS 1.36e-08, SNR 121.17 dB, zero-lag corr 0.99999999999957 |
| G3 real-time safety | pass — ≥5 s live AVAudioSourceNode no-trap; zero malloc delta; p99 0.34% (1 note) / 2.19% (64 voices) of the 11.6 ms deadline |
| G4 hermetic + attributed | pass — gated suites skip without the fixture SF2; MIT LICENSE + NOTICE since the first commit |
| G2-multi multichannel dry PCM equivalence | pass — left: maxAbs 2.83e-07, SNR 124.82 dB; right: maxAbs 2.68e-07, SNR 124.96 dB (bar: ≤1e-4 / ≥80 dB) |
| G-steal voice-stealing behavior | pass — zero dropped notes under saturation; killed → release-tail → never-sustained steal order; older-voice tie-break pinned hermetically |
| G3′-dry real-time safety | pass — ≥5 s multichannel processMidiMessage-driven live no-trap; zero malloc delta incl. full-pool steal bursts; p99 0.46% (1 note) / 9.32% (256 voices) of the 11.6 ms deadline |
| G2-fx effects equivalence | pass — component: hand-derived Freeverb comb/allpass + chorus fractional-delay invariants (no rustysynth component taps — pub(crate)); e2e effects-on vs oracle: left maxAbs 3.13e-07, SNR 122.89 dB; right maxAbs 2.68e-07, SNR 123.11 dB (bar: unchanged dry bar ≤1e-4 / ≥80 dB — decision-table case 1, no calibration) |
| G3-fx real-time safety (effects on) | pass — ≥5 s effects-on live no-trap; zero malloc delta with the effects bus active (strict solo 0/0 witness); p99 1.07% (1 note) / 25.58% (256 voices) of the 11.6 ms deadline |

## Scope so far

SF2 loader (full structural parse) + full-fidelity voice DSP (oscillator,
volume/modulation envelopes, both LFOs, resonant low-pass) + a full
`Synthesizer`: 16 MIDI channels (channel 9 percussion), CC/RPN channel
state, raw `processMidiMessage` dispatch, `SynthesizerSettings` (polyphony
8–256, default 64), dynamic voice allocation with priority stealing — a new
note always sounds; the quietest release tails are reclaimed first — and
the faithful Freeverb reverb + chorus effects bus (send/return per voice,
allocated at init, muted on reset, enabled by default). The MIDI file
sequencer (P3) and the idiomatic `MidiMessage` send API (P4) are the
remaining full-port phases.

## Try it

```sh
swift run -c release SwiftySynthSpike play <path-to.sf2>            # live C4 + timing histogram
swift run -c release SwiftySynthSpike export <path-to.sf2> out.wav  # 5 s float32 WAV
swift test                                                          # gated suites need the reference SF2
```

## Attribution

A Swift port of [MeltySynth](https://github.com/sinshu/meltysynth) by sinshu (MIT).
Test vectors are generated from [rustysynth](https://github.com/sinshu/rustysynth)
via `Tools/oracle` (see `Tests/SwiftySynthTests/Fixtures/README.md`). See `NOTICE` and
`LICENSE`.
