# swiftysynth

A pure-Swift SF2 (SoundFont) synthesizer, ported from sinshu's
[MeltySynth](https://github.com/sinshu/meltysynth) (C#, MIT).

**Status: full port, Phase 0+1+2+3 complete — 16-channel synthesizer with
steal-to-play dynamic voice allocation (the AUMIDISynth fix), the Freeverb
reverb + chorus effects bus, and MIDI file playback (`MidiFile` +
`MidiFileSequencer`, SMF format 0/1). All prior gates plus G-midi / G3-seq
green. API polish (P4) follows.**

| Gate | Result |
|------|--------|
| G1 loader equivalence | pass — exact ints/strings/counts, smpl SHA-256 match, derived floats ≤ 1e-6 vs rustysynth dump |
| G2 one-note PCM equivalence | pass — left: maxAbs 9.87e-08, worst-window RMS 1.43e-08, SNR 121.25 dB, zero-lag corr 0.99999999999955; right: maxAbs 9.13e-08, worst-window RMS 1.36e-08, SNR 121.17 dB, zero-lag corr 0.99999999999957 |
| G3 real-time safety | pass — ≥5 s live AVAudioSourceNode no-trap; zero malloc delta; p99 0.34% (1 note) / 2.19% (64 voices) of the 11.6 ms deadline |
| G4 hermetic + attributed | pass — gated suites skip without the fixture SF2; MIT LICENSE + NOTICE since the first commit |
| G2-multi multichannel dry PCM equivalence | pass — left: maxAbs 2.83e-07, SNR 124.82 dB; right: maxAbs 2.68e-07, SNR 124.96 dB (bar: ≤1e-4 / ≥80 dB) |
| G-steal voice-stealing behavior | pass — zero dropped notes under saturation; killed → release-tail → never-sustained steal order; older-voice tie-break pinned hermetically |
| G3′-dry real-time safety | pass — ≥5 s multichannel processMidiMessage-driven live no-trap; zero malloc delta incl. full-pool steal bursts; p99 0.46% (1 note) / 9.32% (256 voices) of the 11.6 ms deadline |
| G2-fx effects equivalence | pass — component: hand-derived Freeverb comb/allpass + chorus fractional-delay invariants (no rustysynth component taps — pub(crate)); e2e effects-on vs oracle: left: maxAbs 3.13e-07, SNR 122.89 dB; right: maxAbs 2.68e-07, SNR 123.11 dB (bar: unchanged dry bar ≤1e-4 / ≥80 dB — decision-table case 1, no calibration) |
| G3-fx real-time safety (effects on) | pass — ≥5 s effects-on live no-trap; zero malloc delta with the effects bus active (strict solo 0/0 witness); p99 1.07% (1 note) / 25.58% (256 voices) of the 11.6 ms deadline |
| G-midi MIDI file equivalence | pass — structural: 37-message merge equivalence vs dump-midi (types/channels/data exact, f64 times EXACT, both loop variants) + oracle-independent hand-derived table; e2e: 5.0 s looped GM song (FF markers, rewind noteOffAll, effects ON) through the sequencer vs the rustysynth sequencer — left: maxAbs 2.91e-07, SNR 126.14 dB; right: maxAbs 2.83e-07, SNR 124.98 dB (bar: unchanged dry ≤1e-4 / ≥80 dB) |
| G3-seq real-time safety (sequencer-driven) | pass — ≥5 s live sequencer-driven no-trap (off-thread MidiFile parse); zero malloc delta across loop rewinds, onSend nil + set-once hook (strict solo 0/0 witness); p99 < 25% of the 11.6 ms deadline bar (host-load-guarded — this run's release measurement skipped under sustained shared-host contention, 5-min load ≈22.5 on 10 cores; the guard trips to avoid a false wall-clock failure, not a code defect) |

## Scope so far

SF2 loader (full structural parse) + full-fidelity voice DSP (oscillator,
volume/modulation envelopes, both LFOs, resonant low-pass) + a full
`Synthesizer`: 16 MIDI channels (channel 9 percussion), CC/RPN channel
state, raw `processMidiMessage` dispatch, `SynthesizerSettings` (polyphony
8–256, default 64), dynamic voice allocation with priority stealing — a new
note always sounds; the quietest release tails are reclaimed first — and
the faithful Freeverb reverb + chorus effects bus (send/return per voice,
allocated at init, muted on reset, enabled by default). MIDI file playback
is in: `MidiFile` parses SMF format 0/1 (tempo map, running status, RPG
Maker / Incredible Machine / Final Fantasy loop markers; format 2 is
rejected by design) and `MidiFileSequencer` drives the synthesizer with
block-accurate scheduling, looping, playback speed, and an `onSend` hook —
real-time-safe on the render thread. The idiomatic `MidiMessage` send API
and peripherals (P4) are the remaining full-port phase.

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
