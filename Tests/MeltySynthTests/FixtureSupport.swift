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
