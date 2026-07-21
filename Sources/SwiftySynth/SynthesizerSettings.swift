/// A validated, immutable set of synthesis parameters.
///
/// The idiomatic-Swift analogue of `SynthesizerSettings.cs` (MeltySynth, MIT
/// License — see NOTICE): a value type whose throwing initializer performs
/// the range validation C# does in property setters, so any constructed
/// value is valid by construction. Out-of-range values throw
/// `SwiftySynthError.invalidSettings` — never a trap. Ranges and defaults are
/// canonical-faithful (full-port spec §5f): polyphony 8–256 with default 64,
/// no divergence.
public struct SynthesizerSettings: Sendable {
    /// The canonical default block size (`SynthesizerSettings.DefaultBlockSize`).
    public static let defaultBlockSize = 64

    /// The canonical default polyphony (`SynthesizerSettings.DefaultMaximumPolyphony`).
    public static let defaultMaximumPolyphony = 64

    /// The sample rate for synthesis (16000...192000).
    public let sampleRate: Int

    /// The block size for rendering waveform (8...1024, default 64).
    public let blockSize: Int

    /// The number of maximum polyphony (8...256, default 64).
    public let maximumPolyphony: Int

    /// Whether reverb and chorus are enabled (default true). When enabled,
    /// `Synthesizer` allocates the Freeverb/chorus units and their block
    /// buffers at init and mixes the effects return into every rendered
    /// block; when disabled, rendering is fully dry and no effects state
    /// exists.
    public let enableReverbAndChorus: Bool

    /// Whether SF2 note-on modulator support is enabled (default false). When true, `Voice.start`
    /// applies each region's resolved note-on modulators (velocity/keyNumber-sourced, evaluated once
    /// at note-on) to `initialAttenuation` and `initialFilterCutoffFrequency`; when false, rendering
    /// is byte-identical to the pre-modulator engine.
    public let enableModulators: Bool

    public init(
        sampleRate: Int,
        blockSize: Int = SynthesizerSettings.defaultBlockSize,
        maximumPolyphony: Int = SynthesizerSettings.defaultMaximumPolyphony,
        enableReverbAndChorus: Bool = true,
        enableModulators: Bool = false
    ) throws {
        guard 16_000 <= sampleRate && sampleRate <= 192_000 else {
            throw SwiftySynthError.invalidSettings("The sample rate must be between 16000 and 192000.")
        }
        guard 8 <= blockSize && blockSize <= 1_024 else {
            throw SwiftySynthError.invalidSettings("The block size must be between 8 and 1024.")
        }
        guard 8 <= maximumPolyphony && maximumPolyphony <= 256 else {
            throw SwiftySynthError.invalidSettings("The maximum number of polyphony must be between 8 and 256.")
        }
        self.sampleRate = sampleRate
        self.blockSize = blockSize
        self.maximumPolyphony = maximumPolyphony
        self.enableReverbAndChorus = enableReverbAndChorus
        self.enableModulators = enableModulators
    }
}
