import Foundation

/// Per-channel MIDI controller state: the full CC/RPN state machine plus the
/// scaled property getters `Voice` reads every block.
///
/// Ported from `Channel.cs` (MeltySynth, MIT License — see NOTICE). The
/// scaled getters (the numeric path) are the spike's G2-proven code,
/// unchanged; the setter group and RPN dispatch are a direct port with Swift
/// naming. Raw controller state is stored in the exact C# representations
/// (`Int16` fields packed with `<< 7`), and every place C# performs an
/// unchecked `(short)` cast uses `Int16(truncatingIfNeeded:)` — C# truncates
/// silently where Swift's checked conversion would trap (reachable: RPN fine
/// on an unset RPN).
///
/// DIVERGENCE NOTE (vs rustysynth, NOT vs canonical C#): rustysynth's
/// `Channel` tracks NRPN selection (`last_data_type`) and gates data entry on
/// it; canonical `Channel.cs` has no NRPN handling — data entry dispatches
/// purely on the last RPN value, and CC 0x62/0x63 are ignored entirely. This
/// port follows canonical C#. Oracle message streams therefore never send
/// NRPN and always precede data entry with an RPN select, making the two
/// models behaviorally identical for every committed vector.
final class Channel {
    let isPercussionChannel: Bool

    private var bankNumberValue: Int = 0
    private var patchNumberValue: Int = 0

    private var modulationValue: Int16 = 0
    private var volumeValue: Int16 = 0
    private var panValue: Int16 = 0
    private var expressionValue: Int16 = 0
    private var holdPedalValue: Bool = false

    private var reverbSendValue: UInt8 = 0
    private var chorusSendValue: UInt8 = 0

    private var rpnValue: Int16 = 0
    private var pitchBendRangeValue: Int16 = 0
    private var coarseTuneValue: Int16 = 0
    private var fineTuneValue: Int16 = 0

    private var pitchBendValue: Float = 0

    init(isPercussionChannel: Bool) {
        self.isPercussionChannel = isPercussionChannel
        reset()
    }

    /// Mirrors `Channel.Reset`. Copies the raw stored representations
    /// exactly (`short` fields packed with `<< 7`, matching C#'s data-entry
    /// coarse/fine layout) rather than the already-scaled values.
    func reset() {
        bankNumberValue = isPercussionChannel ? 128 : 0
        patchNumberValue = 0

        modulationValue = 0
        volumeValue = 100 << 7
        panValue = 64 << 7
        expressionValue = 127 << 7
        holdPedalValue = false

        reverbSendValue = 40
        chorusSendValue = 0

        rpnValue = -1
        pitchBendRangeValue = 2 << 7
        coarseTuneValue = 0
        fineTuneValue = 8192

        pitchBendValue = 0
    }

    /// Mirrors `Channel.ResetAllControllers` — intentionally PARTIAL: bank,
    /// patch, volume, pan, effects sends, and tuning all survive.
    func resetAllControllers() {
        modulationValue = 0
        expressionValue = 127 << 7
        holdPedalValue = false

        rpnValue = -1

        pitchBendValue = 0
    }

    func setBank(_ value: Int) {
        bankNumberValue = value

        if isPercussionChannel {
            // C#'s `bankNumber += 128` runs as unchecked `int` arithmetic —
            // wrap instead of trapping on an adversarial (out-of-MIDI-range)
            // `value` near `Int.max`.
            bankNumberValue = bankNumberValue &+ 128
        }
    }

    func setPatch(_ value: Int) {
        patchNumberValue = value
    }

    // Each coarse/fine pair packs a 14-bit value into an Int16 exactly as
    // C#'s `(short)((raw & 0x7F) | (value << 7))` / `(short)((raw & 0xFF80) | value)`
    // unchecked casts do — the arithmetic runs in Int (C# int) and truncates
    // on store.

    func setModulationCoarse(_ value: Int) {
        modulationValue = Int16(truncatingIfNeeded: (Int(modulationValue) & 0x7F) | (value << 7))
    }

    func setModulationFine(_ value: Int) {
        modulationValue = Int16(truncatingIfNeeded: (Int(modulationValue) & 0xFF80) | value)
    }

    func setVolumeCoarse(_ value: Int) {
        volumeValue = Int16(truncatingIfNeeded: (Int(volumeValue) & 0x7F) | (value << 7))
    }

    func setVolumeFine(_ value: Int) {
        volumeValue = Int16(truncatingIfNeeded: (Int(volumeValue) & 0xFF80) | value)
    }

    func setPanCoarse(_ value: Int) {
        panValue = Int16(truncatingIfNeeded: (Int(panValue) & 0x7F) | (value << 7))
    }

    func setPanFine(_ value: Int) {
        panValue = Int16(truncatingIfNeeded: (Int(panValue) & 0xFF80) | value)
    }

    func setExpressionCoarse(_ value: Int) {
        expressionValue = Int16(truncatingIfNeeded: (Int(expressionValue) & 0x7F) | (value << 7))
    }

    func setExpressionFine(_ value: Int) {
        expressionValue = Int16(truncatingIfNeeded: (Int(expressionValue) & 0xFF80) | value)
    }

    func setHoldPedal(_ value: Int) {
        holdPedalValue = value >= 64
    }

    func setReverbSend(_ value: Int) {
        reverbSendValue = UInt8(truncatingIfNeeded: value)
    }

    func setChorusSend(_ value: Int) {
        chorusSendValue = UInt8(truncatingIfNeeded: value)
    }

    func setRpnCoarse(_ value: Int) {
        rpnValue = Int16(truncatingIfNeeded: (Int(rpnValue) & 0x7F) | (value << 7))
    }

    func setRpnFine(_ value: Int) {
        rpnValue = Int16(truncatingIfNeeded: (Int(rpnValue) & 0xFF80) | value)
    }

    /// Mirrors `Channel.DataEntryCoarse`: dispatches on the last RPN
    /// selection — 0 = pitch-bend range, 1 = fine tune, 2 = coarse tune
    /// (64-centered); anything else (including -1 = none) is a no-op.
    func dataEntryCoarse(_ value: Int) {
        switch rpnValue {
        case 0:
            pitchBendRangeValue = Int16(truncatingIfNeeded: (Int(pitchBendRangeValue) & 0x7F) | (value << 7))
        case 1:
            fineTuneValue = Int16(truncatingIfNeeded: (Int(fineTuneValue) & 0x7F) | (value << 7))
        case 2:
            // `value - 64` runs as unchecked `int` in C#; use wrapping
            // subtraction so an adversarial `value` near `Int.min` wraps
            // instead of trapping before the truncating downcast.
            coarseTuneValue = Int16(truncatingIfNeeded: value &- 64)
        default:
            break
        }
    }

    /// Mirrors `Channel.DataEntryFine` (no coarse-tune case, per C#).
    func dataEntryFine(_ value: Int) {
        switch rpnValue {
        case 0:
            pitchBendRangeValue = Int16(truncatingIfNeeded: (Int(pitchBendRangeValue) & 0xFF80) | value)
        case 1:
            fineTuneValue = Int16(truncatingIfNeeded: (Int(fineTuneValue) & 0xFF80) | value)
        default:
            break
        }
    }

    /// Mirrors `Channel.SetPitchBend`: 14-bit value, 8192-centered,
    /// normalized to [-1, +1) — the `pitchBend` getter scales by the range.
    /// The final `- 8192` runs as unchecked `int` in C#; use wrapping
    /// subtraction so adversarial `value1`/`value2` near the `Int` extremes
    /// wrap instead of trapping.
    func setPitchBend(_ value1: Int, _ value2: Int) {
        pitchBendValue = (Float(1) / Float(8192)) * Float((value1 | (value2 << 7)) &- 8192)
    }

    var bankNumber: Int { bankNumberValue }
    var patchNumber: Int { patchNumberValue }

    var modulation: Float { (Float(50) / Float(16383)) * Float(modulationValue) }
    var volume: Float { (Float(1) / Float(16383)) * Float(volumeValue) }
    var pan: Float { (Float(100) / Float(16383)) * Float(panValue) - 50 }
    var expression: Float { (Float(1) / Float(16383)) * Float(expressionValue) }
    var holdPedal: Bool { holdPedalValue }

    var reverbSend: Float { (Float(1) / Float(127)) * Float(reverbSendValue) }
    var chorusSend: Float { (Float(1) / Float(127)) * Float(chorusSendValue) }

    var pitchBendRange: Float {
        Float(pitchBendRangeValue >> 7) + 0.01 * Float(pitchBendRangeValue & 0x7F)
    }
    var tune: Float {
        // C#'s `fineTune - 8192` promotes the `short` field to `int` before
        // subtracting (C#'s implicit short→int promotion for arithmetic
        // operators), so it never overflows; widen to `Int` here so the
        // same subtraction can't trap in Swift for an adversarial
        // `fineTuneValue` near `Int16.min`.
        Float(coarseTuneValue) + (Float(1) / Float(8192)) * Float(Int(fineTuneValue) - 8192)
    }

    var pitchBend: Float { pitchBendRange * pitchBendValue }
}
