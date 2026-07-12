# swift-meltysynth

A pure-Swift SF2 (SoundFont) synthesizer, ported from sinshu's
[MeltySynth](https://github.com/sinshu/meltysynth) (C#, MIT).

**Status: vertical-slice spike.** SF2 loader + a single full-fidelity voice +
a minimal synthesizer, built to prove PCM equivalence with a reference
implementation and real-time safety on an `AVAudioSourceNode` render thread
before committing to the full port.

See `NOTICE` and `LICENSE` for attribution.
