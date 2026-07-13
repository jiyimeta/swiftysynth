import Foundation
@testable import SwiftySynth

struct TestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Minimal float32 stereo WAV reader for the oracle vectors (handles hound's output,
/// including any fact/other chunks before data).
enum FloatWav {
    static func read(url: URL) throws -> (left: [Float], right: [Float]) {
        let reader = BinaryReader(data: try Data(contentsOf: url))
        guard try reader.readFourCC() == "RIFF" else { throw TestError("not a RIFF file") }
        _ = try reader.readUInt32()
        guard try reader.readFourCC() == "WAVE" else { throw TestError("not a WAVE file") }

        var format: (tag: Int, channels: Int, sampleRate: Int, bits: Int)?
        while true {
            let id = try reader.readFourCC()
            let size = Int(try reader.readUInt32())
            switch id {
            case "fmt ":
                let tag = Int(try reader.readUInt16())
                let channels = Int(try reader.readUInt16())
                let sampleRate = Int(try reader.readUInt32())
                _ = try reader.readUInt32()   // byte rate
                _ = try reader.readUInt16()   // block align
                let bits = Int(try reader.readUInt16())
                // hound (the oracle's WAV writer) emits WAVE_FORMAT_EXTENSIBLE
                // (tag 0xFFFE) rather than plain WAVE_FORMAT_IEEE_FLOAT (tag 3):
                // a 40-byte fmt chunk with a cbSize/validBits/channelMask/SubFormat
                // extension, where the SubFormat GUID's leading 4 bytes carry the
                // real format code. Resolve the effective tag from there so the
                // "data" case's `f.tag == 3` check still recognizes float32 PCM.
                var effectiveTag = tag
                var consumed = 16
                if tag == 0xFFFE, size >= consumed + 2 + 22 {
                    let cbSize = Int(try reader.readUInt16())
                    consumed += 2
                    if cbSize >= 22 {
                        _ = try reader.readUInt16()   // valid bits per sample
                        _ = try reader.readUInt32()   // channel mask
                        effectiveTag = Int(try reader.readUInt32())   // SubFormat GUID, first 4 bytes
                        try reader.skip(12)            // remaining 12 bytes of the SubFormat GUID
                        consumed += cbSize
                    }
                }
                try reader.skip(size - consumed + (size & 1))
                format = (effectiveTag, channels, sampleRate, bits)
            case "data":
                guard let f = format else { throw TestError("data chunk before fmt") }
                guard f.tag == 3, f.bits == 32, f.channels == 2, f.sampleRate == 44_100 else {
                    throw TestError("unsupported wav layout: \(f)")
                }
                let frames = size / 8
                var left = [Float](repeating: 0, count: frames)
                var right = [Float](repeating: 0, count: frames)
                for i in 0..<frames {
                    left[i] = Float(bitPattern: try reader.readUInt32())
                    right[i] = Float(bitPattern: try reader.readUInt32())
                }
                return (left, right)
            default:
                try reader.skip(size + (size & 1))   // fact/LIST/etc — skip, word-aligned
            }
        }
    }
}
