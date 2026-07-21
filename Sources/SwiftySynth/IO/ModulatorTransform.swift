import Foundation

/// SF2 §8.2/§8.3 source-value transform curves plus the per-modulator note-on evaluator.
///
/// New code with no MeltySynth/C# counterpart to port: MeltySynth never decodes modulator records
/// (it discards them wholesale), so there is nothing here to mirror — this is a
/// from-spec implementation (design spec §3/§4/§6). The concave/convex equations are pinned to
/// FluidSynth's implementable forms (the SF2 §8.2.4 concave equation itself is dimensionally
/// garbled) — see the design spec §3 for the derivation and the default-#1 identity it enables.
extension ModulatorSource {
    /// Maps a raw `0...127` MIDI-style controller value (velocity, key number, a CC value, ...)
    /// through this source's direction/polarity/curve transform (SF2 §8.2.1/§8.2.4), returning a
    /// value in `0...1` (unipolar) or `-1...1` (bipolar). `controller == .none` short-circuits to
    /// the constant `1.0` regardless of `raw127`, per §8.2.1 ("treated as if its value were set to
    /// '1'") — this is normative, not merely a FluidSynth convention.
    func map(_ raw127: Int) -> Float {
        guard controller != .none else { return 1.0 }

        // Normalize to the positive (min→max) domain the curve functions are defined on; a
        // max→min source feeds the mirrored input instead (design spec §3).
        let x = Float(raw127) / 127
        let curveInput = direction == .maxToMin ? 1 - x : x

        let unipolar: Float
        switch curve {
        case .linear:
            unipolar = curveInput
        case .concave:
            unipolar = ModulatorSource.concave(curveInput)
        case .convex:
            unipolar = ModulatorSource.convex(curveInput)
        case .switch:
            unipolar = curveInput >= 0.5 ? 1 : 0
        }

        return polarity == .bipolar ? 2 * unipolar - 1 : unipolar
    }

    /// The positive (min→max, unipolar) concave form (design spec §3): `-(20/96)*log10((1-x)^2)`,
    /// clamped to `[0,1]`. `concave(0) = 0`; `concave(1) = 1` via the clamp — the unclamped log
    /// term diverges to `+∞` as `x → 1` (`log10f(0)` is `-∞`, negated by the leading `-`).
    fileprivate static func concave(_ x: Float) -> Float {
        let value = -(20.0 / 96.0) * log10f((1 - x) * (1 - x))
        return min(max(value, 0), 1)
    }

    /// The mirror of `concave` (design spec §3): `convex(x) = 1 - concave(1 - x)`, clamped to
    /// `[0,1]`.
    fileprivate static func convex(_ x: Float) -> Float {
        min(max(1 - concave(1 - x), 0), 1)
    }
}

extension Modulator {
    /// This modulator's contribution to its destination generator, for one (velocity, key) pair,
    /// in the destination's raw units (cB for `initialAttenuation`, cents for the pitch/time
    /// generators, ...): `amount × source.map(primaryRaw) × amountSource.map(secondaryRaw)`, with
    /// `transform == .absoluteValue` taking the absolute value of that product (SF2 §8.3).
    ///
    /// `primaryRaw`/`secondaryRaw` are `velocity`/`key` when the corresponding source's controller
    /// is `.velocity`/`.keyNumber`; `.none` ignores its raw input entirely (`map` short-circuits to
    /// `1.0`), so any placeholder works there. Combining multiple modulators' outputs into a
    /// per-generator sum is a later task (design spec §5's resolved-list machinery) — this is only
    /// the single-record evaluation `Voice.start` (via that later machinery) will call per note-on.
    func output(velocity: Int, key: Int) -> Float {
        let primary = source.map(Modulator.rawInput(for: source.controller, velocity: velocity, key: key))
        let secondary = amountSource.map(
            Modulator.rawInput(for: amountSource.controller, velocity: velocity, key: key))
        let value = Float(amount) * primary * secondary
        return transform == .absoluteValue ? abs(value) : value
    }

    /// The `0...127` raw controller value a note-on source's `map` should be evaluated at.
    /// `.cc`/`.other` never actually reach here — design spec §5/§6 restricts the resolved
    /// per-region modulator list to note-on sources (`.none`/`.velocity`/`.keyNumber`) before
    /// `output` is ever called — so their raw choice is arbitrary and only matters for
    /// defensive completeness.
    private static func rawInput(for controller: ModulatorController, velocity: Int, key: Int) -> Int {
        switch controller {
        case .velocity:
            return velocity
        case .keyNumber:
            return key
        case .none, .cc, .other:
            return 127
        }
    }
}
