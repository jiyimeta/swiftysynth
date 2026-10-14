import CryptoKit
import Foundation
import Testing
@testable import SwiftySynth

/// Reference-font policy (spec §4): the ~32 MB GeneralUser-GS font is NOT
/// committed (it would bloat every SwiftPM consumer's clone), so fixture tests
/// are gated on its existence and skip when it is absent. Following the upstream
/// convention — rustysynth resolves its test SF2 relative to `CARGO_MANIFEST_DIR`,
/// MeltySynth references it by bare filename — the default location is
/// `GeneralUser-GS.sf2` at the package root. Set `SWIFTYSYNTH_SF2` to point at a
/// copy elsewhere (the G4 hermeticity check also uses it to simulate absence).
enum FixtureSF2 {
    /// `<package root>/GeneralUser-GS.sf2`, derived at compile time from
    /// `#filePath` (= `<package>/Tests/SwiftySynthTests/FixtureSupport.swift`,
    /// so three parent hops reach the package directory) — the SwiftPM analogue
    /// of rustysynth's `CARGO_MANIFEST_DIR`-relative lookup. No absolute path is
    /// baked into the source.
    static let defaultPath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/SwiftySynthTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root
        .appendingPathComponent("GeneralUser-GS.sf2")
        .path
    static var path: String {
        ProcessInfo.processInfo.environment["SWIFTYSYNTH_SF2"] ?? defaultPath
    }
    static var exists: Bool { FileManager.default.fileExists(atPath: path) }
    static var url: URL { URL(fileURLWithPath: path) }
}

enum Fixtures {
    static func url(_ name: String, _ ext: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
    }
}

enum TestEnv {
    static var isRelease: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// SHA-256 over the little-endian byte serialization of the samples — the exact
/// definition the oracle's dump-font uses.
func smplSHA256(_ samples: WaveData) -> String {
    // Apple platforms are little-endian, so the in-memory bytes ARE the LE serialization.
    let data = Array(samples).withUnsafeBufferPointer { Data(buffer: $0) }
    return sha256Hex(data)
}

/// Renders `range` of `synth`'s output into the matching slice of `left`/`right`.
/// Exercises `Synthesizer.render`'s `UnsafeMutableBufferPointer` entry point
/// against a plain `[Float]`-backed caller buffer, one arbitrary-sized chunk
/// at a time (used to drive the partial-block carry across odd call sizes).
func renderInto(_ synth: Synthesizer, _ left: inout [Float], _ right: inout [Float], _ range: Range<Int>) {
    left.withUnsafeMutableBufferPointer { lp in
        right.withUnsafeMutableBufferPointer { rp in
            synth.render(
                left: UnsafeMutableBufferPointer(rebasing: lp[range]),
                right: UnsafeMutableBufferPointer(rebasing: rp[range]))
        }
    }
}
