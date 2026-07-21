import Foundation
import Testing
@testable import SwiftySynth

/// Hermetic. `ModulatorSource.map`/`Modulator.output` — the SF2 §8.2/§8.3 source transform curves
/// (concave/convex/switch/linear, direction, polarity) plus the per-modulator note-on evaluator
/// added for the optional note-on-modulator feature (design spec §3/§4). Nothing yet combines
/// multiple modulators into a per-generator sum (spec §5, a later task); this covers only the
/// single-record transform + evaluation, including the default-#1 identity against the hardcoded
/// velocity-attenuation curve (`Voice.swift:141`).
struct ModulatorTransformTests {
    private let acc: Float = 1e-4

    /// Builds one 10-byte imod/pmod record: srcOper, destOper (generator), amount, amtSrcOper,
    /// transform — same encoding `ModulatorDecodeTests.swift` uses, so the source-word bit layout
    /// doesn't need re-deriving here (`ModulatorSource(rawValue:)` is exercised, not a memberwise
    /// init — `ModulatorSource`/`Modulator` have none beyond `init(rawValue:)`/`read(from:)`).
    private func record(src: UInt16, dest: UInt16, amount: Int16, amtSrc: UInt16, transform: UInt16)
        -> BinaryReader
    {
        var w = ByteWriter()
        w.u16(src)
        w.u16(dest)
        w.i16(amount)
        w.u16(amtSrc)
        w.u16(transform)
        return BinaryReader(data: w.data)
    }

    // concave(x) = -(20/96)*log10((1-x)^2), clamped [0,1]; here x = raw/127, positive (minToMax).
    // src 0x0402: index=2 (velocity), CC=0, D=0 (minToMax), P=0 (unipolar), curveType=1 (concave).
    @Test func concaveEndpointsAndMidpoint() throws {
        let s = try Modulator.read(from: record(src: 0x0402, dest: 48, amount: 100, amtSrc: 0, transform: 0)).source
        #expect(abs(s.map(0) - 0.0) < acc)
        #expect(abs(s.map(127) - 1.0) < acc)
        // Concave stays well below the linear response through the middle of the range and only
        // rises steeply near the top (x=64/127≈0.504: -(20/96)*log10((1-x)^2) ≈ 0.127) — check
        // against the pinned formula itself rather than a magic constant.
        let x: Float = 64.0 / 127.0
        let expectedMidpoint = min(max(-(20.0 / 96.0) * log10f((1 - x) * (1 - x)), 0), 1)
        #expect(abs(s.map(64) - expectedMidpoint) < acc)
        #expect(s.map(64) < 0.5, "concave bows below the linear line before rising sharply near the top")
    }

    // src 0x0000: index=0 (none), CC=0, D=0, P=0, curveType=0 (linear) -- controller is irrelevant
    // to the shape here since `.none` short-circuits `map` regardless of curve.
    @Test func noneIsConstantOne() throws {
        let s = try Modulator.read(from: record(src: 0x0000, dest: 48, amount: 100, amtSrc: 0, transform: 0)).source
        #expect(abs(s.map(0) - 1.0) < acc)
        #expect(abs(s.map(127) - 1.0) < acc)
    }

    // src 0x0C02: index=2 (velocity), CC=0, D=0 (minToMax), P=0 (unipolar), curveType=3 (switch).
    @Test func switchThreshold() throws {
        let s = try Modulator.read(from: record(src: 0x0C02, dest: 48, amount: 100, amtSrc: 0, transform: 0)).source
        #expect(abs(s.map(63) - 0.0) < acc) // below half
        #expect(abs(s.map(64) - 1.0) < acc) // at/above half
    }

    /// SF2 default #1 (src 0x0502: concave, D=1 maxToMin, index=2 velocity; dest
    /// initialAttenuation; amount 960; amtSrc 0x0 none; transform 0 linear — same record
    /// `ModulatorDecodeTests.default1Decode` already validated the decode of). Its output (in cB)
    /// must equal the hardcoded `2*linearToDecibels(velocity/127)` term (`Voice.swift:141`,
    /// negated to express attenuation rather than gain) at every velocity — the analytic identity
    /// design spec §4 pins: `960*(-20/96)*log10((v/127)^2)` cB == `-40*log10(v/127)` dB.
    @Test func default1OutputMatchesHardcodedCurve() throws {
        let m = try Modulator.read(from: record(src: 0x0502, dest: 48, amount: 960, amtSrc: 0x0, transform: 0))
        for v in [1, 32, 64, 80, 100, 127] {
            let attenCB = m.output(velocity: v, key: 60) // cB, positive attenuation
            let attenDB = 0.1 * attenCB
            let hardcodedDB = -2 * SoundFontMath.linearToDecibels(Float(v) / 127) // matches Voice.swift:141, negated
            #expect(abs(attenDB - hardcodedDB) < 1e-4, "default #1 must equal the hardcoded curve at v=\(v)")
        }
    }
}
