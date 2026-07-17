/// The non-standard loop extension to recognize when loading a MIDI file.
///
/// Ported from `MidiFileLoopType.cs` (MeltySynth, MIT License — see NOTICE).
public enum MidiFileLoopType: Sendable {
    /// No special loop extension.
    case none

    /// The RPG Maker style loop: CC #111 marks the loop start point.
    case rpgMaker

    /// The Incredible Machine style loop: CC #110 and #111 mark the loop
    /// start and end points.
    case incredibleMachine

    /// The Final Fantasy style loop: CC #116 and #117 mark the loop start
    /// and end points.
    case finalFantasy
}
