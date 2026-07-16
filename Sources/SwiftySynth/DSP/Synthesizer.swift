import Foundation

/// The full 16-channel SoundFont synthesizer — dry path (the reverb/chorus
/// bus lands in Phase 2; `enableReverbAndChorus` is stored and validated, but
/// until P2 rendering is always dry).
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

    /// Whether reverb and chorus are enabled. P1: stored but inert — the
    /// effects units are ported in Phase 2; rendering is dry until then.
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
    }

    /// Initializes a new synthesizer using a specified SoundFont and sample
    /// rate, with the canonical default settings (block 64, polyphony 64).
    public convenience init(soundFont: SoundFont, sampleRate: Int) throws {
        try self.init(soundFont: soundFont, settings: SynthesizerSettings(sampleRate: sampleRate))
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

    /// Resets the synthesizer: clears all voices, resets every channel to its
    /// MIDI defaults, and restarts the block carry. (P2 adds
    /// `reverb.mute()` / `chorus.mute()` here.)
    public func reset() {
        voices.clear()

        for channel in channels {
            channel.reset()
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

    /// Mirrors `Synthesizer.RenderBlock` (dry half): `voices.process()`
    /// advances/compacts the pool, then the surviving active prefix is mixed
    /// in order — the same summation order as C#'s enumerator. The mix-gain
    /// arithmetic is byte-for-byte the spike's G2-proven code.
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

        // P2 adds here, gated on `enableReverbAndChorus`: the chorus send
        // build + process + multiplyAdd, then the reverb send (inputGain ×
        // reverbSend × (mixGainLeft + mixGainRight)) + process + multiplyAdd
        // (Synthesizer.cs RenderBlock's second half).
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
}
