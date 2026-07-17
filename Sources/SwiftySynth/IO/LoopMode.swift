/// Specifies how the synthesizer loops the sample.
///
/// Ported from `LoopMode.cs` (MeltySynth, MIT License — see NOTICE). Raw
/// values are the SF2 wire values used by the `sampleModes` generator; wire
/// value 2 maps to `.noLoop` (SF2-spec quirk), but that mapping is
/// region-side behavior, not part of this enum.
public enum LoopMode: Int, Sendable {
    /// The sample will be played without loop.
    case noLoop = 0

    /// The sample will continuously loop.
    case continuous = 1

    /// The sample will loop until the note stops.
    case loopUntilNoteOff = 3
}
