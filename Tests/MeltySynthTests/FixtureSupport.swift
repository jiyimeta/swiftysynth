import CryptoKit
import Foundation
import Testing
@testable import MeltySynth

/// The locked reference-font policy (spec §4): absolute path, tests gated on existence.
/// MELTYSYNTH_SF2 exists so the G4 hermeticity check can simulate the font's absence
/// (and so another machine could point at its own copy).
enum FixtureSF2 {
    static let lockedPath =
        "GeneralUser-GS.sf2"
    static var path: String {
        ProcessInfo.processInfo.environment["MELTYSYNTH_SF2"] ?? lockedPath
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
func smplSHA256(_ samples: [Int16]) -> String {
    // Apple platforms are little-endian, so the in-memory bytes ARE the LE serialization.
    let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
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
