import Foundation
@testable import SwiftySynth

/// Builds a decoded `Modulator` via the real byte-decode path (`Modulator.read`), since
/// `Modulator`'s memberwise init is file-private (its validity flags cap the synthesized init to
/// `Modulator.swift`'s own scope). Mirrors the 10-byte `pmod`/`imod` record shape used by
/// `ModulatorDecodeTests.record(...)`: srcOper, destOper, amount, amtSrcOper, transformOper.
func makeModulator(src: UInt16, dest: UInt16, amount: Int16, amtSrc: UInt16 = 0, transform: UInt16 = 0)
    -> Modulator
{
    var w = ByteWriter()
    w.u16(src)
    w.u16(dest)
    w.i16(amount)
    w.u16(amtSrc)
    w.u16(transform)
    return try! Modulator.read(from: BinaryReader(data: w.data))
}

/// Convenience for the common SF2 default modulator #1 shape (velocity -> initialAttenuation,
/// concave curve, maxToMin direction): src word `0x0502`, dest `48` (initialAttenuation).
func makeVelocityToAttenuationModulator(amount: Int16) -> Modulator {
    makeModulator(src: 0x0502, dest: 48, amount: amount)
}
