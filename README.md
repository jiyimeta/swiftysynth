# swiftysynth

A pure-Swift SF2 (SoundFont) synthesizer, ported from sinshu's
[MeltySynth](https://github.com/sinshu/meltysynth) (C#, MIT).

**Status: full port COMPLETE — Phases 0–4, all gates green.** A 16-channel
SF2 synthesizer with steal-to-play dynamic voice allocation (the
AUMIDISynth fix: a new note always sounds; inaudible voices and the
quietest release tails are reclaimed first), the faithful Freeverb reverb +
chorus effects bus, MIDI file playback (SMF format 0/1, looping, tempo
map), and an idiomatic Swift API over a faithful, oracle-pinned core.

## Requirements

- Swift 6 (swift-tools-version 6.0), macOS 13+ / iOS 16+
- The core library depends on Foundation only — never AVFoundation. Host
  audio I/O (e.g. an `AVAudioSourceNode` render callback) belongs to the
  embedding app.

## Installation

Swift Package Manager. The repository is not yet published to a public
host; add it as a local package until then:

```swift
// Package.swift
dependencies: [
    .package(path: "../swiftysynth")
]
// target dependency: .product(name: "SwiftySynth", package: "swiftysynth")
```

## Quick start

```swift
import SwiftySynth

// Load and build once, OFF the audio thread. All allocation happens here.
let soundFont = try SoundFont(url: sf2URL)
let settings = try SynthesizerSettings(sampleRate: 44_100)  // block 64, polyphony 64, effects on
let synthesizer = try Synthesizer(soundFont: soundFont, settings: settings)

// Send MIDI — the typed enum, or the raw fast path the sequencer uses:
synthesizer.send(.programChange(0), to: 0)
synthesizer.send(.noteOn(key: 60, velocity: 100), to: 0)
synthesizer.processMidiMessage(channel: 0, command: 0x90, data1: 64, data2: 100)

// Render stereo frames into your own buffers — alloc-free, lock-free.
var left = [Float](repeating: 0, count: 512)
var right = [Float](repeating: 0, count: 512)
left.withUnsafeMutableBufferPointer { l in
    right.withUnsafeMutableBufferPointer { r in
        synthesizer.render(left: l, right: r)
    }
}
```

### MIDI file playback

```swift
let midi = try MidiFile(url: midURL, loopType: .finalFantasy)  // or MidiFile(url:) without loop markers
let sequencer = MidiFileSequencer(synthesizer: synthesizer)
sequencer.play(midi, loop: true)
// In the render callback, call sequencer.render(left:right:) instead of
// synthesizer.render. position, isAtEnd, speed, and the onSend hook are
// available; parse MidiFile off the render thread and set onSend once,
// before rendering starts.
```

## Real-time contract

- Everything is allocated at init. After the host engine starts, `render`,
  `send`, `processMidiMessage`, and the sequencer's `render` allocate
  nothing and take no locks (gate-verified: G3′/G3-fx/G3-seq).
- `Synthesizer` and `MidiFileSequencer` are single-owner and NOT
  thread-safe: playback control and rendering on different threads must be
  serialized by the caller (the C# reference documents the same contract).
- Malformed SF2/SMF bytes throw `SwiftySynthError` — file-derived data
  never traps the host process.
- Building an `AVAudioSourceNode` render block? Construct it in a
  `nonisolated static` factory — a block formed in a `@MainActor` context
  traps on the audio thread (see `Sources/SwiftySynthSpike`).

## Scope

Supported: full SF2 structural parse (16-bit `smpl`), the complete
per-voice DSP chain (oscillator, volume/modulation envelopes, both LFOs,
resonant low-pass), 16 MIDI channels (channel 9 percussion) with CC/RPN
state, priority voice stealing (polyphony 8–256, default 64), Freeverb
reverb + chorus, SMF format 0/1 + General MIDI, RPG Maker / Incredible
Machine / Final Fantasy loop markers, optional SF2 note-on modulator
support (off by default — see [Modulators](#modulators)).

Not supported — canonical-faithful stances, by design: `sm24` 24-bit
samples; SMF format 2 (throws `.invalidMidiFile`); real-time SF2
modulators, the synthesized default filter-cutoff modulator, and linked
modulators (see [Modulators](#modulators)); NRPN (ignored, as in canonical
`Channel.cs`).

## Modulators

Optional, **default OFF**. Enable via:

```swift
let settings = try SynthesizerSettings(sampleRate: 44_100, enableModulators: true)
```

**Why OFF by default.** SwiftySynth is a faithful port of MeltySynth, which
does not implement modulators. Keeping modulators off preserves byte-identical
output, the MeltySynth-equivalence test oracles, and SoundFont load
compatibility — every font that loads today keeps loading, unchanged.

**What IS applied when ON.** SF2 **note-on** modulators — sources limited to
note-on velocity, note-on key number, and the constant `none` — are resolved
at SoundFont load per the SF2 §9.5.1 combining rules (default →
instrument-override → preset-additive, with global/local-zone supersession)
and applied once at note start. The SF2 default velocity→`initialAttenuation`
modulator (default #1) is included and replaces the port's hardcoded velocity
curve. The resolved modulator sums are currently applied to two generator
destinations: `initialAttenuation` and `initialFilterCutoffFrequency`.

**Not yet supported:**
- Real-time / continuously-varying modulators — any CC/MIDI-controller
  source, channel or polyphonic pressure, or pitch-wheel source.
- The synthesized SF2 default modulator #2 (velocity → filter cutoff).
- Linked modulators.
- Modulator application to note-on destinations other than attenuation and
  filter cutoff — e.g. coarse/fine tune, mod-envelope, LFO depth, filter Q.
  These are recognized and resolved but not yet applied.

Invalid or unsupported modulator records, and malformed modulator bag
indices, are skipped at load and never fail loading; a `pmod`/`imod` chunk
whose size is not a whole number of 10-byte records is rejected.

## Gates (equivalence + safety record)

| Gate | Result |
|------|--------|
| G1 loader equivalence | pass — exact ints/strings/counts, smpl SHA-256 match, derived floats ≤ 1e-6 vs rustysynth dump |
| G1′ peripherals | pass — pmod/imod parsed; invalid/malformed records skipped, never thrown (size-validated, unit-pinned); every GeneralUser-GS sample header decodes to a known SampleType |
| G2 one-note PCM equivalence | pass — left: maxAbs 9.87e-08, worst-window RMS 1.43e-08, SNR 121.25 dB, zero-lag corr 0.99999999999955; right: maxAbs 9.13e-08, worst-window RMS 1.36e-08, SNR 121.17 dB, zero-lag corr 0.99999999999957 |
| G2-multi multichannel dry PCM equivalence | pass — left: maxAbs 2.83e-07, SNR 124.82 dB; right: maxAbs 2.68e-07, SNR 124.96 dB (bar: ≤1e-4 / ≥80 dB) |
| G2-fx effects equivalence | pass — component: hand-derived Freeverb comb/allpass + chorus fractional-delay invariants; e2e effects-on vs oracle: left: maxAbs 3.13e-07, SNR 122.89 dB; right: maxAbs 2.68e-07, SNR 123.11 dB (bar: unchanged dry bar ≤1e-4 / ≥80 dB) |
| G-steal voice-stealing behavior | pass — zero dropped notes under saturation; killed → release-tail → never-sustained steal order; older-voice tie-break pinned hermetically |
| G-midi MIDI file equivalence | pass — structural: 37-message merge equivalence vs dump-midi (types/channels/data exact, f64 times EXACT, both loop variants) + oracle-independent hand-derived table; e2e: 5.0 s looped GM song (FF markers, rewind noteOffAll, effects ON) through the sequencer vs the rustysynth sequencer — left: maxAbs 2.91e-07, SNR 126.14 dB; right: maxAbs 2.83e-07, SNR 124.98 dB (bar: unchanged dry ≤1e-4 / ≥80 dB) |
| MidiMessage ≡ raw dispatch (P4) | pass — every enum case maps to one raw `processMidiMessage` call: channel-state equality across mirrored scripts + bit-identical PCM from twin effects-on synthesizers (hermetic) |
| G3 / G3′ / G3-fx real-time safety | pass — ≥5 s live AVAudioSourceNode no-trap (dry, effects-on, steal bursts); zero malloc delta (strict solo 0/0 witness); p99 of the 11.6 ms deadline: 0.46% (1 note, dry) / 9.32% (256 voices, dry) / 1.07% / 25.58% (effects on) |
| G3-seq real-time safety (sequencer-driven) | pass — ≥5 s live sequencer-driven no-trap (off-thread MidiFile parse); zero malloc delta across loop rewinds, onSend nil + set-once hook (strict solo 0/0 witness); p99 0.82% of the 11.6 ms deadline (release, worst of three runs; measured at host load ~5 on 10 cores — a conservative upper bound, a fully idle host would be lower) |
| G4 hermetic + attributed | pass — re-verified at P4 close: `swift test` green with no reference SF2 (gated suites skip; MIDI + peripheral suites run hermetically), no network/Rust at test time; MIT LICENSE + NOTICE since the first commit |

Test vectors are committed; tests never invoke the oracle. See
`Tests/SwiftySynthTests/Fixtures/README.md` for provenance and
regeneration.

## Verifying

```sh
swift test                        # font-gated suites need the reference SF2 (point SWIFTYSYNTH_SF2 elsewhere if needed)
swift test -c release             # adds the CPU-budget gates (they skip themselves on a loaded host)
Scripts/verify-rt-gates.sh        # the solo strict zero-alloc witnesses (exact 0/0, hard-asserted)
swift run -c release SwiftySynthSpike play <path-to.sf2>            # live C4 + timing histogram
swift run -c release SwiftySynthSpike export <path-to.sf2> out.wav  # 5 s float32 WAV
```

## Attribution

A Swift port of [MeltySynth](https://github.com/sinshu/meltysynth) by sinshu (MIT).
Test vectors are generated from [rustysynth](https://github.com/sinshu/rustysynth)
via `Tools/oracle` (see `Tests/SwiftySynthTests/Fixtures/README.md`). See `NOTICE` and
`LICENSE`.
