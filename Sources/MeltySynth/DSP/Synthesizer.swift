import Foundation

/// The minimal spike synthesizer: owns a fixed voice pool and one `Channel`,
/// and renders block-64 stereo audio via a simple two-gain-ramp mix loop.
///
/// Ported from `Synthesizer.cs` (MeltySynth, MIT License — see NOTICE), with
/// `SynthesizerSettings.cs`'s constants folded in as fixed values/init
/// defaults (`blockSize = 64`, `masterVolume = 0.5` initial —
/// `SynthesizerSettings.DefaultBlockSize`/`Synthesizer`'s `masterVolume`
/// field initializer), `ArrayMath.cs`'s `MultiplyAdd` overloads folded into
/// `writeBlock` below, and `VoiceCollection.cs` simplified to a fixed pool
/// (see `requestVoice`'s doc comment for exactly what's kept vs dropped).
///
/// SPIKE scope narrowing vs `Synthesizer.cs`:
/// - Single hardwired channel 0, with its preset resolved once at `init` to
///   the SoundFont's bank-0/patch-0 preset (`init` throws
///   `MeltySynthError.invalidSoundFont` if none exists) — no 16-channel
///   array, no MIDI CC/RPN dispatch (`ProcessMidiMessage`), no percussion
///   channel, no program-change bank/patch lookup or GM-fallback chain.
/// - No reverb/chorus bus (`Chorus.cs`/`Reverb.cs`/
///   `SynthesizerSettings.EnableReverbAndChorus` are out of scope).
/// - No sequencer / MIDI file playback, no `Reset`/`NoteOffAll`.
public final class Synthesizer {
    /// The sample rate for synthesis.
    public let sampleRate: Int

    /// The block size for rendering waveform. Always 64
    /// (`SynthesizerSettings.DefaultBlockSize`).
    public let blockSize: Int

    /// The number of maximum polyphony (the fixed voice-pool size).
    public let maximumPolyphony: Int

    /// The master volume. Defaults to 0.5 (`Synthesizer.cs`'s
    /// `masterVolume = 0.5F;` field initializer).
    public var masterVolume: Float

    private let soundFont: SoundFont
    private let defaultPreset: Preset

    private let channel: Channel

    /// The fixed voice pool, allocated once at `init`. Never resized —
    /// `requestVoice` reuses a `Voice` in place (SPIKE: simplified
    /// `VoiceCollection`, see its doc comment) rather than growing the
    /// array, so the render path never allocates.
    private let voices: [Voice]

    private var blockLeft: [Float]
    private var blockRight: [Float]

    private let inverseBlockSize: Float

    private var blockRead: Int

    /// Initializes a new synthesizer using a specified SoundFont and sample
    /// rate. Mirrors `Synthesizer(SoundFont, SynthesizerSettings)`, with
    /// `SynthesizerSettings`'s constants (block size 64, default max
    /// polyphony) folded in directly.
    ///
    /// ALLOCATION DISCIPLINE: every array here (the voice pool — including
    /// each `Voice`'s own 64-frame `block` — and the `blockLeft`/
    /// `blockRight` mix buffers) is allocated in this initializer. After
    /// `init` returns, `render`/`noteOn`/`noteOff` allocate nothing.
    public init(soundFont: SoundFont, sampleRate: Int, maximumPolyphony: Int = 8) throws {
        self.soundFont = soundFont
        self.sampleRate = sampleRate
        self.blockSize = 64
        self.maximumPolyphony = maximumPolyphony

        // SPIKE: bank 0 / patch 0 is the only preset this spike ever plays —
        // no bank-select/program-change dispatch, no `presetLookup`
        // dictionary, no GM-fallback chain (`Synthesizer.cs`'s `NoteOn`
        // falls back through the patch-only and 128:0 percussion-kit preset
        // IDs before settling on `defaultPreset`; this port has exactly one
        // channel and hardwires straight to bank0/patch0).
        guard let preset = soundFont.presets.first(where: { $0.bankNumber == 0 && $0.patchNumber == 0 }) else {
            throw MeltySynthError.invalidSoundFont("The SoundFont has no bank 0 / patch 0 preset.")
        }
        self.defaultPreset = preset

        self.channel = Channel()

        var voices: [Voice] = []
        voices.reserveCapacity(maximumPolyphony)
        for _ in 0..<maximumPolyphony {
            voices.append(Voice(sampleRate: sampleRate, blockSize: blockSize))
        }
        self.voices = voices

        self.blockLeft = [Float](repeating: 0, count: blockSize)
        self.blockRight = [Float](repeating: 0, count: blockSize)

        self.inverseBlockSize = 1 / Float(blockSize)

        self.blockRead = blockSize

        self.masterVolume = 0.5
    }

    /// The number of voices currently being played. Mirrors
    /// `VoiceCollection.ActiveVoiceCount`, adapted to this port's flag-based
    /// fixed pool: counts pool voices whose `isActive` is currently true.
    public var activeVoiceCount: Int {
        var count = 0
        for voice in voices where voice.isActive {
            count += 1
        }
        return count
    }

    /// Starts a note on the (sole, hardwired) channel. Mirrors
    /// `Synthesizer.NoteOn` narrowed to a single channel: velocity 0 is
    /// treated as a note-off (matching `Synthesizer.cs`'s own `if (velocity
    /// == 0) { NoteOff(...); return; }` at the top of `NoteOn`); otherwise
    /// every preset region containing (key, velocity), crossed with every
    /// contained region of its linked instrument, forms a `RegionPair` and
    /// starts a free (or exclusive-class-matching) pool voice.
    public func noteOn(key: Int, velocity: Int) {
        if velocity == 0 {
            noteOff(key: key)
            return
        }

        for presetRegion in defaultPreset.regions where presetRegion.contains(key: key, velocity: velocity) {
            for instrumentRegion in presetRegion.instrument.regions where instrumentRegion.contains(key: key, velocity: velocity) {
                let region = RegionPair(preset: presetRegion, instrument: instrumentRegion)
                guard let voice = requestVoice(exclusiveClass: instrumentRegion.exclusiveClass) else {
                    // SPIKE: the pool is exhausted. Canonical
                    // `VoiceCollection.RequestNew` steals the active voice
                    // with the lowest `Voice.Priority` (tie-broken by the
                    // oldest `VoiceLength`) in this situation; priority-based
                    // stealing is explicitly out of scope for this spike, so
                    // the new voice is simply dropped instead.
                    continue
                }
                voice.start(region: region, channel: channel, data: soundFont.waveData, key: key, velocity: velocity)
            }
        }
    }

    /// Stops a note on the (sole, hardwired) channel. Mirrors
    /// `Synthesizer.NoteOff` narrowed to a single channel: every active
    /// voice at this key moves to its release phase.
    public func noteOff(key: Int) {
        for voice in voices where voice.isActive && voice.key == key {
            voice.end()
        }
    }

    /// Finds a voice to (re)start for a new note. Mirrors
    /// `VoiceCollection.RequestNew`'s first two branches exactly — reuse an
    /// active voice sharing this `exclusiveClass` (region-authored "choke"
    /// behavior, e.g. closed/open hi-hat; NOT related to voice stealing), or
    /// fall back to the next free (never-started-or-since-died) pool slot.
    /// SPIKE: the third branch (steal the active voice with the lowest
    /// priority once the pool is full) is dropped — see `noteOn`'s doc
    /// comment. Returns `nil` in exactly that dropped case.
    private func requestVoice(exclusiveClass: Int) -> Voice? {
        if exclusiveClass != 0 {
            for voice in voices where voice.isActive && voice.exclusiveClass == exclusiveClass {
                return voice
            }
        }

        for voice in voices where !voice.isActive {
            return voice
        }

        return nil
    }

    /// Renders `left.count` (== `right.count`) frames, carrying any partial
    /// block across calls. Mirrors `Synthesizer.Render` exactly: `blockRead`
    /// starts at `blockSize` (forcing an immediate `renderBlock` on the very
    /// first call), and each iteration copies `min(blockSize - blockRead,
    /// remaining)` frames out of the current mix block before refilling.
    /// Correct for any caller chunk size (64-aligned or not) and across any
    /// number of calls.
    public func render(left: UnsafeMutableBufferPointer<Float>, right: UnsafeMutableBufferPointer<Float>) {
        precondition(left.count == right.count)

        var wrote = 0
        while wrote < left.count {
            if blockRead == blockSize {
                renderBlock()
                blockRead = 0
            }

            let srcRem = blockSize - blockRead
            let dstRem = left.count - wrote
            let rem = min(srcRem, dstRem)

            for i in 0..<rem {
                left[wrote + i] = blockLeft[blockRead + i]
                right[wrote + i] = blockRight[blockRead + i]
            }

            blockRead += rem
            wrote += rem
        }
    }

    /// Mirrors `Synthesizer.RenderBlock`, minus the reverb/chorus mixdown
    /// (out of scope — see the class doc comment). Advances every active
    /// voice by one block, mixing surviving voices into `blockLeft`/
    /// `blockRight`; a voice whose `process()` returns false is left with
    /// `isActive == false` (set by `Voice.process` itself) and is not mixed
    /// this block, freeing its pool slot for `requestVoice`.
    private func renderBlock() {
        for i in 0..<blockLeft.count {
            blockLeft[i] = 0
            blockRight[i] = 0
        }

        for voice in voices where voice.isActive {
            guard voice.process() else {
                continue
            }

            let previousGainLeft = masterVolume * voice.previousMixGainLeft
            let currentGainLeft = masterVolume * voice.currentMixGainLeft
            writeBlock(previousGain: previousGainLeft, currentGain: currentGainLeft, source: voice.block, destination: &blockLeft)

            let previousGainRight = masterVolume * voice.previousMixGainRight
            let currentGainRight = masterVolume * voice.currentMixGainRight
            writeBlock(previousGain: previousGainRight, currentGain: currentGainRight, source: voice.block, destination: &blockRight)
        }
    }

    /// Mirrors `Synthesizer.WriteBlock`, with `ArrayMath.cs`'s two
    /// `MultiplyAdd` overloads folded in as the flat/ramped branches below.
    /// Copy the exact thresholds and formula shape:
    /// - `max(previousGain, currentGain) < SoundFontMath.nonAudible` → skip
    ///   entirely (both endpoints are inaudible).
    /// - `abs(currentGain - previousGain) < 1.0e-3` → flat multiply-add
    ///   (`ArrayMath.MultiplyAdd(float, float[], float[])`).
    /// - otherwise → linear ramp across the block
    ///   (`ArrayMath.MultiplyAdd(float, float, float[], float[])`), stepping
    ///   `previousGain` toward `currentGain` by `(currentGain -
    ///   previousGain) / blockSize` per sample.
    private func writeBlock(previousGain: Float, currentGain: Float, source: [Float], destination: inout [Float]) {
        if max(previousGain, currentGain) < SoundFontMath.nonAudible {
            return
        }

        if abs(currentGain - previousGain) < 1.0e-3 {
            for t in 0..<destination.count {
                destination[t] += currentGain * source[t]
            }
        } else {
            let step = inverseBlockSize * (currentGain - previousGain)
            var gain = previousGain
            for t in 0..<destination.count {
                destination[t] += gain * source[t]
                gain += step
            }
        }
    }
}
