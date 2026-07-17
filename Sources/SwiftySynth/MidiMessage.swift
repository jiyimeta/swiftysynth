/// An idiomatic, typed MIDI message — the Swift-friendly layer over the
/// faithful raw `Synthesizer.processMidiMessage(channel:command:data1:data2:)`
/// dispatch (full-port spec §6).
///
/// The five cases are exactly the commands the synthesizer acts on
/// (`Synthesizer.cs ProcessMidiMessage`); everything else the raw path
/// ignores, so no other cases exist. Channel-mode messages travel as
/// control changes, as on the wire: all-sound-off =
/// `.controlChange(controller: 0x78, value: 0)`, reset-all-controllers =
/// `0x79`, all-notes-off = `0x7B`. See `processMidiMessage` for the full
/// list of controllers the synthesizer responds to.
///
/// Values are NOT validated: like the raw path (and the C# reference),
/// out-of-range data passes through unclamped — garbage in, garbage out,
/// never a trap. The sequencer and other performance-sensitive callers use
/// the raw path directly; this wrapper adds no state and no allocation.
public enum MidiMessage: Equatable, Sendable {
    /// Note off (`0x80`). Release velocity is not modeled — the reference
    /// synthesizer ignores it (64, the MIDI default, is sent on the wire).
    case noteOff(key: Int)

    /// Note on (`0x90`). Velocity 0 is a note off (the MIDI running-status
    /// convention, honored by the raw path).
    case noteOn(key: Int, velocity: Int)

    /// Control change (`0xB0`) with the raw controller number (0...127).
    case controlChange(controller: Int, value: Int)

    /// Program change (`0xC0`).
    case programChange(Int)

    /// Pitch bend (`0xE0`): the raw 14-bit value, 0...16383, center 8192.
    /// The bend range in semitones is the channel's RPN 0 state
    /// (default ±2).
    case pitchBend(Int)
}

extension Synthesizer {
    /// Sends an idiomatic `MidiMessage` by forwarding to the faithful raw
    /// dispatch — byte-identical to calling
    /// `processMidiMessage(channel:command:data1:data2:)` with the same
    /// wire values (proven by `MidiMessageTests`). Real-time-safe: no
    /// allocation, no locks, no validation.
    public func send(_ message: MidiMessage, to channel: Int) {
        switch message {
        case .noteOff(let key):
            processMidiMessage(channel: channel, command: 0x80, data1: key, data2: 64)
        case .noteOn(let key, let velocity):
            processMidiMessage(channel: channel, command: 0x90, data1: key, data2: velocity)
        case .controlChange(let controller, let value):
            processMidiMessage(channel: channel, command: 0xB0, data1: controller, data2: value)
        case .programChange(let program):
            processMidiMessage(channel: channel, command: 0xC0, data1: program, data2: 0)
        case .pitchBend(let value):
            processMidiMessage(channel: channel, command: 0xE0, data1: value & 0x7F, data2: (value >> 7) & 0x7F)
        }
    }
}
