import Foundation
import Testing
@testable import SwiftySynth

/// Hermetic. `Modulator.read`/`isValid`/`isNoteOn` — the decoded modulator record + validity/
/// note-on predicates added for the optional note-on-modulator feature (full-port spec §2). This
/// covers only the decode + predicates; nothing yet consumes a `Modulator` (later tasks do), and
/// `Modulator.discardData` (covered by ModulatorTests.swift) is unchanged.
struct ModulatorDecodeTests {
    /// Builds one 10-byte imod/pmod record: srcOper, destOper (generator), amount, amtSrcOper,
    /// transform.
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

    /// SF2 default #1: src 0x0502 (type1 concave, D=1 maxToMin, P=0, CC=0, index=2 velocity),
    /// dest initialAttenuation(48), amount 960, amtSrc 0x0, transform 0.
    @Test func default1Decode() throws {
        let reader = record(src: 0x0502, dest: 48, amount: 960, amtSrc: 0x0, transform: 0)
        let m = try Modulator.read(from: reader)
        #expect(m.source.controller == .velocity)
        #expect(m.source.curve == .concave)
        #expect(m.source.direction == .maxToMin)
        #expect(m.destination == .initialAttenuation)
        #expect(m.amount == 960)
        #expect(m.isValid)
        #expect(m.isNoteOn)
    }

    /// type=2 convex -> bits set at 10..11 (value 2 << 10 = 0x0800), type=3 switch (0x0C00).
    /// index=2 (velocity) in both.
    @Test func convexAndSwitchTypesAreValid() throws {
        let convex = try Modulator.read(from: record(src: 0x0802, dest: 48, amount: 100, amtSrc: 0, transform: 0))
        let sw = try Modulator.read(from: record(src: 0x0C02, dest: 48, amount: 100, amtSrc: 0, transform: 0))
        #expect(convex.isValid, "convex(2) must be accepted (bits 12-15 rule, not 11-15)")
        #expect(sw.isValid, "switch(3) must be accepted")
    }

    /// type=4 (value 4 << 10 = 0x1000, bit 12 set) -> invalid.
    @Test func unknownCurveTypeIsInvalid() throws {
        let m = try Modulator.read(from: record(src: 0x1002, dest: 48, amount: 100, amtSrc: 0, transform: 0))
        #expect(!m.isValid)
    }

    /// CC flag set (bit 7), index 1 (mod wheel): valid record but not note-on.
    @Test func ccSourceIsNotNoteOn() throws {
        let m = try Modulator.read(from: record(src: 0x0081, dest: 48, amount: 100, amtSrc: 0, transform: 0))
        #expect(!m.isNoteOn)
    }

    /// destOper bit 15 set -> linked -> invalid.
    @Test func linkedDestinationIsInvalid() throws {
        let m = try Modulator.read(from: record(src: 0x0502, dest: 0x8000, amount: 100, amtSrc: 0, transform: 0))
        #expect(!m.isValid)
    }

    /// dest = sampleID (53) is an index generator, not a Value Generator -> invalid.
    @Test func nonValueGeneratorDestinationIsInvalid() throws {
        let m = try Modulator.read(from: record(src: 0x0502, dest: 53, amount: 100, amtSrc: 0, transform: 0))
        #expect(!m.isValid)
    }
}
