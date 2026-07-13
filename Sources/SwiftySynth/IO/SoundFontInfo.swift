import Foundation

/// Represents the version of a SoundFont.
///
/// Ported from `SoundFontVersion.cs` (MeltySynth, MIT License — see NOTICE).
/// C# models this as a `struct` with an `internal` constructor and public
/// `Major`/`Minor` properties; the Swift port relies on the compiler's
/// synthesized memberwise initializer, which defaults to `internal` access
/// even though the type and its stored properties are `public` — the same
/// "readable but not directly constructible outside the module" shape as
/// the C# original.
public struct SoundFontVersion: Sendable {
    public let major: Int16
    public let minor: Int16
}

/// The information of a SoundFont (the `LIST`/`INFO` chunk).
///
/// Ported from `SoundFontInfo.cs` (MeltySynth, MIT License — see NOTICE).
public final class SoundFontInfo {
    public let version: SoundFontVersion
    public let targetSoundEngine: String
    public let bankName: String
    public let romName: String
    public let romVersion: SoundFontVersion
    public let creationDate: String
    public let author: String
    public let targetProduct: String
    public let copyright: String
    public let comments: String
    public let tools: String

    /// Reads the whole `LIST`/`INFO` chunk: fourCC + size + `INFO` form,
    /// then iterates sub-chunks by ID until `size` bytes are consumed.
    /// Mirrors `SoundFontInfo`'s internal constructor exactly, including its
    /// default-empty-string behavior for absent string sub-chunks and its
    /// hard failure on any sub-chunk ID it doesn't recognize.
    init(reader: BinaryReader) throws {
        var version = SoundFontVersion(major: 0, minor: 0)
        var targetSoundEngine = ""
        var bankName = ""
        var romName = ""
        var romVersion = SoundFontVersion(major: 0, minor: 0)
        var creationDate = ""
        var author = ""
        var targetProduct = ""
        var copyright = ""
        var comments = ""
        var tools = ""

        let chunkId = try reader.readFourCC()
        guard chunkId == "LIST" else {
            throw SwiftySynthError.invalidSoundFont("The LIST chunk was not found.")
        }

        // `end` is captured right after reading the chunk size (before the
        // `INFO` form fourCC is read), so it accounts for the form fourCC's
        // 4 bytes too — matches C#'s `end += reader.BaseStream.Position`
        // ordering exactly. `Int` is 64-bit on every platform this package
        // targets, so widening an `Int32` chunk size here can never overflow
        // or trap, even if the size is negative (mirroring C#'s `long end`).
        let size = try reader.readInt32()
        let end = reader.position + Int(size)

        let listType = try reader.readFourCC()
        guard listType == "INFO" else {
            throw SwiftySynthError.invalidSoundFont(
                "The type of the LIST chunk must be 'INFO', but was '\(listType)'."
            )
        }

        while reader.position < end {
            let id = try reader.readFourCC()
            let chunkSize = Int(try reader.readInt32())

            switch id {
            case "ifil":
                version = SoundFontVersion(major: try reader.readInt16(), minor: try reader.readInt16())
            case "isng":
                // A negative/oversized `chunkSize` is rejected by
                // `readFixedLengthString`'s own bounds check (it throws
                // `SwiftySynthError.unexpectedEndOfData` rather than trap),
                // so no extra guard is needed at this call site.
                targetSoundEngine = try reader.readFixedLengthString(chunkSize)
            case "INAM":
                bankName = try reader.readFixedLengthString(chunkSize)
            case "irom":
                romName = try reader.readFixedLengthString(chunkSize)
            case "iver":
                romVersion = SoundFontVersion(major: try reader.readInt16(), minor: try reader.readInt16())
            case "ICRD":
                creationDate = try reader.readFixedLengthString(chunkSize)
            case "IENG":
                author = try reader.readFixedLengthString(chunkSize)
            case "IPRD":
                targetProduct = try reader.readFixedLengthString(chunkSize)
            case "ICOP":
                copyright = try reader.readFixedLengthString(chunkSize)
            case "ICMT":
                comments = try reader.readFixedLengthString(chunkSize)
            case "ISFT":
                tools = try reader.readFixedLengthString(chunkSize)
            default:
                throw SwiftySynthError.invalidSoundFont("The INFO list contains an unknown ID '\(id)'.")
            }
        }

        self.version = version
        self.targetSoundEngine = targetSoundEngine
        self.bankName = bankName
        self.romName = romName
        self.romVersion = romVersion
        self.creationDate = creationDate
        self.author = author
        self.targetProduct = targetProduct
        self.copyright = copyright
        self.comments = comments
        self.tools = tools
    }
}
