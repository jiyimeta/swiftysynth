import Foundation
import Testing
@testable import SwiftySynth

/// `SampleType` decoding — the G1′ closeout leg (spec §7: "`SampleType`
/// decoding"). Hermetic: the SampleType.cs vocabulary, the synthetic font,
/// and garbage-in → nil (never a trap). Fixture-gated: every sample header
/// in the reference font decodes to a known type.
struct SampleTypeTests {
    /// The eight values of SampleType.cs, exactly.
    @Test func vocabularyMatchesSampleTypeCs() {
        #expect(SampleType(rawValue: 1) == .mono)
        #expect(SampleType(rawValue: 2) == .right)
        #expect(SampleType(rawValue: 4) == .left)
        #expect(SampleType(rawValue: 8) == .linked)
        #expect(SampleType(rawValue: 0x8001) == .romMono)
        #expect(SampleType(rawValue: 0x8002) == .romRight)
        #expect(SampleType(rawValue: 0x8004) == .romLeft)
        #expect(SampleType(rawValue: 0x8008) == .romLinked)
    }

    /// File bytes can hold anything; unknown values decode to nil — the
    /// loader's throw-not-trap posture, in optional form.
    @Test func garbageValuesDecodeToNilNotATrap() {
        for raw: Int32 in [0, 3, 5, 6, 7, 9, 0x10, 0x8000, 0x8010, 0x7FFF, Int32.max] {
            #expect(SampleType(rawValue: raw) == nil, "raw \(raw)")
        }
    }

    /// The synthetic font writes sampleType = 1; the raw field is untouched
    /// and the typed accessor reads mono.
    @Test func syntheticFontSampleIsMono() throws {
        let font = try SoundFont(data: SyntheticSF2.minimal())
        let header = try #require(font.sampleHeaders.first)
        #expect(header.sampleType == 1)
        #expect(header.type == .mono)
    }

    /// G1′ on real data: every GeneralUser-GS sample header decodes. This
    /// reference font's 920 samples are entirely single-channel — verified
    /// independently against the raw `shdr` bytes (no stereo-split
    /// left/right/linked pairs) — and, being a software wavetable font,
    /// it carries no ROM samples either.
    @Test(.enabled(if: FixtureSF2.exists, "GeneralUser GS not present at the locked path"))
    func referenceFontDecodesEveryHeader() throws {
        let font = try SoundFont(url: FixtureSF2.url)
        var counts: [SampleType: Int] = [:]
        for header in font.sampleHeaders {
            let type = try #require(
                header.type,
                "\(header.name): raw sampleType \(header.sampleType) is outside the SFSampleLink vocabulary")
            counts[type, default: 0] += 1
        }
        #expect(counts[.mono] == font.sampleHeaders.count)
        #expect(counts[.left] == nil && counts[.right] == nil && counts[.linked] == nil)
        #expect(counts[.romMono] == nil && counts[.romRight] == nil
                && counts[.romLeft] == nil && counts[.romLinked] == nil,
                "a wavetable font must not carry ROM sample types")
        print("G1'-sampletype: mono=\(counts[.mono] ?? 0) left=\(counts[.left] ?? 0) right=\(counts[.right] ?? 0) linked=\(counts[.linked] ?? 0) total=\(font.sampleHeaders.count)")
    }
}
