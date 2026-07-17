/// The full 16-channel SoundFont synthesizer with the Freeverb reverb +
/// chorus effects bus (allocated at init iff `enableReverbAndChorus`;
/// rendering is fully dry — bit-identical to the pre-effects build — when
/// disabled).
///
/// Ported from `Synthesizer.cs` (MeltySynth, MIT License — see NOTICE). The
/// STRUCTURE is idiomatic Swift: `SynthesizerSettings` value-type init,
/// dictionary preset lookup, `VoiceCollection` ownership, thrown
/// `SwiftySynthError` instead of exceptions/asserts. The NUMERIC path —
/// `renderBlock`'s mix loop, `writeBlock`'s gain ramp (ArrayMath.cs folded
/// in), and the partial-block carry in `render` — is the spike's G2-proven
/// faithful code, unchanged.
///
/// ALLOCATION DISCIPLINE (spec §8): everything — the voice pool (each voice's
/// render block included), the 16 channels, the preset lookup, the mix
/// buffers — is allocated in `init`. After a host engine starts,
/// `render`/`noteOn`/`noteOff`/`noteOffAll`/`processMidiMessage` allocate
/// nothing and take no locks.
///
/// Threading: NOT thread-safe, mirroring the reference's documented contract.
/// After the host's `start()` the instance is touched exclusively by the
/// audio thread; control and render on separate threads must be serialized by
/// the caller.
public final class Synthesizer {
    /// The number of MIDI channels. Always 16.
    public static let channelCount = 16

    /// The percussion channel index. Always 9.
    public static let percussionChannel = 9

    /// The SoundFont used as the audio source.
    public let soundFont: SoundFont

    /// The sample rate for synthesis.
    public let sampleRate: Int

    /// The block size for rendering waveform.
    public let blockSize: Int

    /// The number of maximum polyphony (the voice-pool size, 8...256).
    public let maximumPolyphony: Int

    /// Whether reverb and chorus are enabled. When true, `init` allocates
    /// the effects units and their block buffers (`effects != nil`) and
    /// `renderBlock` mixes the effects return into every block.
    public let enableReverbAndChorus: Bool

    /// The master volume. Defaults to 0.5 (`Synthesizer.cs`'s field initializer).
    public var masterVolume: Float

    /// The number of voices currently being played.
    public var activeVoiceCount: Int { voices.activeVoiceCount }

    private let presetLookup: [Int: Preset]
    private let defaultPreset: Preset

    /// Channel 9 is percussion. Internal (not private) for @testable tests.
    let channels: [Channel]

    /// The steal-to-play voice pool. Internal (not private) for @testable tests.
    let voices: VoiceCollection

    /// The preallocated effects bus — non-nil iff `enableReverbAndChorus`.
    /// Internal (not private) for @testable tests.
    let effects: Effects?

    private var blockLeft: [Float]
    private var blockRight: [Float]

    private let inverseBlockSize: Float

    private var blockRead: Int

    /// Initializes a new synthesizer using a specified SoundFont and settings.
    /// Mirrors `Synthesizer(SoundFont, SynthesizerSettings)`.
    public init(soundFont: SoundFont, settings: SynthesizerSettings) throws {
        self.soundFont = soundFont
        self.sampleRate = settings.sampleRate
        self.blockSize = settings.blockSize
        self.maximumPolyphony = settings.maximumPolyphony
        self.enableReverbAndChorus = settings.enableReverbAndChorus

        // Preset lookup: ID = (bank << 16) | patch. First occurrence wins
        // (C# Dictionary.TryAdd), and the minimum ID becomes the default
        // preset — for a GM-compatible font, the Grand Piano.
        var presetLookup = [Int: Preset]()
        presetLookup.reserveCapacity(soundFont.presets.count)
        var defaultPreset: Preset? = nil
        var minPresetId = Int.max
        for preset in soundFont.presets {
            let presetId = (preset.bankNumber << 16) | preset.patchNumber
            if presetLookup[presetId] == nil {
                presetLookup[presetId] = preset
            }
            if presetId < minPresetId {
                defaultPreset = preset
                minPresetId = presetId
            }
        }
        guard let defaultPreset else {
            // C# covers this with Debug.Assert; file-derived data must never
            // trap this port, so an empty preset list throws instead.
            throw SwiftySynthError.invalidSoundFont("The SoundFont contains no presets.")
        }
        self.presetLookup = presetLookup
        self.defaultPreset = defaultPreset

        self.channels = (0..<Synthesizer.channelCount).map {
            Channel(isPercussionChannel: $0 == Synthesizer.percussionChannel)
        }

        self.voices = VoiceCollection(
            sampleRate: settings.sampleRate,
            blockSize: settings.blockSize,
            maximumPolyphony: settings.maximumPolyphony)

        self.blockLeft = [Float](repeating: 0, count: settings.blockSize)
        self.blockRight = [Float](repeating: 0, count: settings.blockSize)

        self.inverseBlockSize = 1 / Float(settings.blockSize)

        self.blockRead = settings.blockSize

        self.masterVolume = 0.5

        self.effects = settings.enableReverbAndChorus
            ? Effects(sampleRate: settings.sampleRate, blockSize: settings.blockSize)
            : nil
    }

    /// Initializes a new synthesizer using a specified SoundFont and sample
    /// rate, with the canonical default settings (block 64, polyphony 64).
    public convenience init(soundFont: SoundFont, sampleRate: Int) throws {
        try self.init(soundFont: soundFont, settings: SynthesizerSettings(sampleRate: sampleRate))
    }

    /// Processes a raw MIDI message — the FAITHFUL dispatch path
    /// (`Synthesizer.cs ProcessMidiMessage`, byte-value for byte-value); the
    /// idiomatic `MidiMessage` wrapper (`send(_:to:)`, `MidiMessage.swift`)
    /// layers on top of this path.
    ///
    /// Deliberately unhandled, matching canonical C#: NRPN (CC 0x62/0x63) —
    /// rustysynth diverges here (it gates data entry on an RPN/NRPN flag), so
    /// committed oracle streams avoid NRPN and precede data entry with an RPN
    /// select. Unknown commands and unlisted CCs are ignored.
    public func processMidiMessage(channel: Int, command: Int, data1: Int, data2: Int) {
        guard 0 <= channel && channel < channels.count else {
            return
        }
        let channelInfo = channels[channel]

        switch command {
        case 0x80: // Note Off
            noteOff(key: data1, on: channel)

        case 0x90: // Note On
            noteOn(key: data1, velocity: data2, on: channel)

        case 0xB0: // Controller
            switch data1 {
            case 0x00: channelInfo.setBank(data2)               // Bank Selection
            case 0x01: channelInfo.setModulationCoarse(data2)   // Modulation Coarse
            case 0x21: channelInfo.setModulationFine(data2)     // Modulation Fine
            case 0x06: channelInfo.dataEntryCoarse(data2)       // Data Entry Coarse
            case 0x26: channelInfo.dataEntryFine(data2)         // Data Entry Fine
            case 0x07: channelInfo.setVolumeCoarse(data2)       // Channel Volume Coarse
            case 0x27: channelInfo.setVolumeFine(data2)         // Channel Volume Fine
            case 0x0A: channelInfo.setPanCoarse(data2)          // Pan Coarse
            case 0x2A: channelInfo.setPanFine(data2)            // Pan Fine
            case 0x0B: channelInfo.setExpressionCoarse(data2)   // Expression Coarse
            case 0x2B: channelInfo.setExpressionFine(data2)     // Expression Fine
            case 0x40: channelInfo.setHoldPedal(data2)          // Hold Pedal
            case 0x5B: channelInfo.setReverbSend(data2)         // Reverb Send
            case 0x5D: channelInfo.setChorusSend(data2)         // Chorus Send
            case 0x65: channelInfo.setRpnCoarse(data2)          // RPN Coarse
            case 0x64: channelInfo.setRpnFine(data2)            // RPN Fine
            case 0x78: noteOffAll(channel: channel, immediate: true)    // All Sound Off
            case 0x79: resetAllControllers(channel: channel)            // Reset All Controllers
            case 0x7B: noteOffAll(channel: channel, immediate: false)   // All Note Off
            default: break
            }

        case 0xC0: // Program Change
            channelInfo.setPatch(data1)

        case 0xE0: // Pitch Bend
            channelInfo.setPitchBend(data1, data2)

        default:
            break
        }
    }

    /// Starts a note. Mirrors `Synthesizer.NoteOn`: velocity 0 is a note-off;
    /// the channel's (bank, patch) resolves through the lookup, then the GM
    /// fallback (patch under bank 0, or the standard percussion set 128:0 for
    /// drum banks), then the default preset. Every matching preset-region ×
    /// instrument-region pair starts a voice — and `requestNew` never fails,
    /// so the note ALWAYS sounds (steal-to-play; the AUMIDISynth fix).
    public func noteOn(key: Int, velocity: Int, on channel: Int) {
        if velocity == 0 {
            noteOff(key: key, on: channel)
            return
        }

        guard 0 <= channel && channel < channels.count else {
            return
        }
        let channelInfo = channels[channel]

        let presetId = (channelInfo.bankNumber << 16) | channelInfo.patchNumber
        var preset = presetLookup[presetId]
        if preset == nil {
            let gmPresetId = channelInfo.bankNumber < 128 ? channelInfo.patchNumber : (128 << 16)
            preset = presetLookup[gmPresetId]
        }
        let resolvedPreset = preset ?? defaultPreset

        for presetRegion in resolvedPreset.regions where presetRegion.contains(key: key, velocity: velocity) {
            for instrumentRegion in presetRegion.instrument.regions where instrumentRegion.contains(key: key, velocity: velocity) {
                let regionPair = RegionPair(preset: presetRegion, instrument: instrumentRegion)
                let voice = voices.requestNew(region: instrumentRegion, channel: channel)
                voice.start(
                    region: regionPair, channel: channel, channelInfo: channelInfo,
                    data: soundFont.waveData, key: key, velocity: velocity)
            }
        }
    }

    /// Stops a note: every active voice at (channel, key) moves to release.
    public func noteOff(key: Int, on channel: Int) {
        guard 0 <= channel && channel < channels.count else {
            return
        }

        for i in 0..<voices.activeVoiceCount {
            let voice = voices[i]
            if voice.channel == channel && voice.key == key {
                voice.end()
            }
        }
    }

    /// Stops all notes. Mirrors `Synthesizer.NoteOffAll(bool)`: immediate
    /// clears the pool outright; otherwise every voice enters release.
    public func noteOffAll(immediate: Bool) {
        if immediate {
            voices.clear()
        } else {
            for i in 0..<voices.activeVoiceCount {
                voices[i].end()
            }
        }
    }

    /// Stops all notes on one channel. Mirrors
    /// `Synthesizer.NoteOffAll(int, bool)`: immediate kills (silences with no
    /// release; the voice leaves the pool on its next process), else releases.
    public func noteOffAll(channel: Int, immediate: Bool) {
        for i in 0..<voices.activeVoiceCount {
            let voice = voices[i]
            guard voice.channel == channel else { continue }
            if immediate {
                voice.kill()
            } else {
                voice.end()
            }
        }
    }

    /// Mirrors `Synthesizer.ResetAllControllers()`.
    public func resetAllControllers() {
        for channel in channels {
            channel.resetAllControllers()
        }
    }

    /// Mirrors `Synthesizer.ResetAllControllers(int)`.
    public func resetAllControllers(channel: Int) {
        guard 0 <= channel && channel < channels.count else {
            return
        }
        channels[channel].resetAllControllers()
    }

    /// Resets the synthesizer: clears all voices, resets every channel to
    /// its MIDI defaults, mutes the reverb/chorus tails, and restarts the
    /// block carry. Mirrors `Synthesizer.Reset`.
    public func reset() {
        voices.clear()

        for channel in channels {
            channel.reset()
        }

        if let effects {
            effects.reverb.mute()
            effects.chorus.mute()
        }

        blockRead = blockSize
    }

    /// Renders `left.count` (== `right.count`) frames, carrying any partial
    /// block across calls. Mirrors `Synthesizer.Render` exactly — UNCHANGED
    /// spike code (G2-proven): correct for any caller chunk size and across
    /// any number of calls.
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

    /// Mirrors `Synthesizer.RenderBlock`: `voices.process()` advances/
    /// compacts the pool, the surviving active prefix is mixed dry in order
    /// (the spike's G2-proven byte-for-byte gain arithmetic), then — when
    /// effects are enabled — the chorus and reverb send/return half runs
    /// (see the inline comment below).
    private func renderBlock() {
        voices.process()

        for i in 0..<blockLeft.count {
            blockLeft[i] = 0
            blockRight[i] = 0
        }
        for i in 0..<voices.activeVoiceCount {
            let voice = voices[i]

            let previousGainLeft = masterVolume * voice.previousMixGainLeft
            let currentGainLeft = masterVolume * voice.currentMixGainLeft
            writeBlock(previousGain: previousGainLeft, currentGain: currentGainLeft, source: voice.block, destination: &blockLeft)

            let previousGainRight = masterVolume * voice.previousMixGainRight
            let currentGainRight = masterVolume * voice.currentMixGainRight
            writeBlock(previousGain: previousGainRight, currentGain: currentGainRight, source: voice.block, destination: &blockRight)
        }

        // Effects half, faithful to `Synthesizer.cs` RenderBlock: build the
        // STEREO chorus send (chorusSend × mixGain per side), process, and
        // return at masterVolume; then the MONO reverb send
        // (inputGain × reverbSend × (mixGainLeft + mixGainRight)), process,
        // return at masterVolume. All buffers preallocated in `Effects`;
        // this path allocates nothing (spec §8).
        if let effects {
            for i in 0..<effects.chorusInputLeft.count {
                effects.chorusInputLeft[i] = 0
                effects.chorusInputRight[i] = 0
            }
            for i in 0..<voices.activeVoiceCount {
                let voice = voices[i]

                let previousGainLeft = voice.previousChorusSend * voice.previousMixGainLeft
                let currentGainLeft = voice.currentChorusSend * voice.currentMixGainLeft
                writeBlock(previousGain: previousGainLeft, currentGain: currentGainLeft, source: voice.block, destination: &effects.chorusInputLeft)

                let previousGainRight = voice.previousChorusSend * voice.previousMixGainRight
                let currentGainRight = voice.currentChorusSend * voice.currentMixGainRight
                writeBlock(previousGain: previousGainRight, currentGain: currentGainRight, source: voice.block, destination: &effects.chorusInputRight)
            }
            effects.chorus.process(
                inputLeft: effects.chorusInputLeft, inputRight: effects.chorusInputRight,
                outputLeft: &effects.chorusOutputLeft, outputRight: &effects.chorusOutputRight)
            ArrayMath.multiplyAdd(masterVolume, effects.chorusOutputLeft, &blockLeft)
            ArrayMath.multiplyAdd(masterVolume, effects.chorusOutputRight, &blockRight)

            for i in 0..<effects.reverbInput.count {
                effects.reverbInput[i] = 0
            }
            for i in 0..<voices.activeVoiceCount {
                let voice = voices[i]

                let previousGain = effects.reverb.inputGain * voice.previousReverbSend * (voice.previousMixGainLeft + voice.previousMixGainRight)
                let currentGain = effects.reverb.inputGain * voice.currentReverbSend * (voice.currentMixGainLeft + voice.currentMixGainRight)
                writeBlock(previousGain: previousGain, currentGain: currentGain, source: voice.block, destination: &effects.reverbInput)
            }
            effects.reverb.process(
                input: effects.reverbInput,
                outputLeft: &effects.reverbOutputLeft, outputRight: &effects.reverbOutputRight)
            ArrayMath.multiplyAdd(masterVolume, effects.reverbOutputLeft, &blockLeft)
            ArrayMath.multiplyAdd(masterVolume, effects.reverbOutputRight, &blockRight)
        }
    }

    /// Mirrors `Synthesizer.WriteBlock`, with `ArrayMath.cs`'s two
    /// `MultiplyAdd` overloads folded in as the flat/ramped branches below —
    /// UNCHANGED spike code (G2-proven). Copy the exact thresholds:
    /// - `max(previousGain, currentGain) < SoundFontMath.nonAudible` → skip.
    /// - `abs(currentGain - previousGain) < 1.0e-3` → flat multiply-add.
    /// - otherwise → linear ramp, stepping by `(current - previous) / blockSize`.
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

    /// The preallocated effects bus (rustysynth's `Effects` struct
    /// analogue; C# holds the same nine members as nullable fields on
    /// `Synthesizer`). Exists iff `enableReverbAndChorus`. Every buffer is
    /// allocated HERE, at synthesizer init, and only mutated in place by
    /// `renderBlock` — the render path allocates nothing (spec §8).
    final class Effects {
        let reverb: Reverb
        let chorus: Chorus

        var reverbInput: [Float]
        var reverbOutputLeft: [Float]
        var reverbOutputRight: [Float]

        var chorusInputLeft: [Float]
        var chorusInputRight: [Float]
        var chorusOutputLeft: [Float]
        var chorusOutputRight: [Float]

        init(sampleRate: Int, blockSize: Int) {
            reverb = Reverb(sampleRate: sampleRate)
            reverbInput = [Float](repeating: 0, count: blockSize)
            reverbOutputLeft = [Float](repeating: 0, count: blockSize)
            reverbOutputRight = [Float](repeating: 0, count: blockSize)

            // The canonical chorus parameters (`Synthesizer.cs` ctor):
            // delay 0.002 s, depth 0.0019 s, LFO frequency 0.4 Hz.
            chorus = Chorus(sampleRate: sampleRate, delay: 0.002, depth: 0.0019, frequency: 0.4)
            chorusInputLeft = [Float](repeating: 0, count: blockSize)
            chorusInputRight = [Float](repeating: 0, count: blockSize)
            chorusOutputLeft = [Float](repeating: 0, count: blockSize)
            chorusOutputRight = [Float](repeating: 0, count: blockSize)
        }
    }
}
