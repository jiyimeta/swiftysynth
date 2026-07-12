import Foundation

/// Per-channel MIDI controller state, scaled into the ranges `Voice` reads
/// every block.
///
/// Ported from `Channel.cs` (MeltySynth, MIT License — see NOTICE), limited
/// to the reset-default state, `reset()`, and the scaled property getters —
/// CC/RPN message dispatch (`SetModulationCoarse`/`Fine`, `SetVolumeCoarse`/
/// `Fine`, `SetPanCoarse`/`Fine`, `SetExpressionCoarse`/`Fine`,
/// `SetHoldPedal`, `SetReverbSend`, `SetChorusSend`, `SetRpnCoarse`/`Fine`,
/// `DataEntryCoarse`/`Fine`, `SetPitchBend`, `SetBank`, `SetPatch`,
/// `ResetAllControllers`), the `IsPercussionChannel`/`HoldPedal` getters, and
/// the `synthesizer`/`isPercussionChannel` fields are out of spike scope —
/// the spike drives voices directly rather than via MIDI CC, so this port
/// always behaves as a non-percussion channel (`Reset()`'s
/// `isPercussionChannel ? 128 : 0` branch collapses to the `0` case). A full
/// port would re-add the omitted surface.
final class Channel {
    private var bankNumberValue: Int = 0
    private var patchNumberValue: Int = 0

    private var modulationValue: Int16 = 0
    private var volumeValue: Int16 = 0
    private var panValue: Int16 = 0
    private var expressionValue: Int16 = 0

    private var reverbSendValue: UInt8 = 0
    private var chorusSendValue: UInt8 = 0

    private var pitchBendRangeValue: Int16 = 0
    private var coarseTuneValue: Int16 = 0
    private var fineTuneValue: Int16 = 0

    private var pitchBendValue: Float = 0

    init() {
        reset()
    }

    /// Mirrors `Channel.Reset`. Copies the raw stored representations
    /// exactly (`short` fields packed with `<< 7`, matching C#'s data-entry
    /// coarse/fine layout) rather than the already-scaled values.
    func reset() {
        bankNumberValue = 0
        patchNumberValue = 0

        modulationValue = 0
        volumeValue = 100 << 7
        panValue = 64 << 7
        expressionValue = 127 << 7

        reverbSendValue = 40
        chorusSendValue = 0

        pitchBendRangeValue = 2 << 7
        coarseTuneValue = 0
        fineTuneValue = 8192

        pitchBendValue = 0
    }

    var bankNumber: Int { bankNumberValue }
    var patchNumber: Int { patchNumberValue }

    var modulation: Float { (Float(50) / Float(16383)) * Float(modulationValue) }
    var volume: Float { (Float(1) / Float(16383)) * Float(volumeValue) }
    var pan: Float { (Float(100) / Float(16383)) * Float(panValue) - 50 }
    var expression: Float { (Float(1) / Float(16383)) * Float(expressionValue) }

    var reverbSend: Float { (Float(1) / Float(127)) * Float(reverbSendValue) }
    var chorusSend: Float { (Float(1) / Float(127)) * Float(chorusSendValue) }

    var pitchBendRange: Float {
        Float(pitchBendRangeValue >> 7) + 0.01 * Float(pitchBendRangeValue & 0x7F)
    }
    var tune: Float {
        Float(coarseTuneValue) + (Float(1) / Float(8192)) * Float(fineTuneValue - 8192)
    }

    var pitchBend: Float { pitchBendRange * pitchBendValue }
}
