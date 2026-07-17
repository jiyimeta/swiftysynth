import Foundation

/// A parsed Standard MIDI File (SMF format 0 or 1): all tracks merged onto
/// one absolute-time message list with the tempo map applied.
///
/// Ported from `MidiFile.cs` (MeltySynth, MIT License — see NOTICE).
/// FAITHFUL (full-port spec §3, §5e): the byte-level decode (variable-length
/// quantities, running status, meta/SysEx discarding, the after-EOT skip)
/// and the merge/tempo arithmetic decide which bytes become which events at
/// which time — transliterated, not restructured. ONE locked deviation
/// (plan Global Constraints): times accumulate in `Double` seconds,
/// operation-for-operation identical to rustysynth's f64 — NOT C#'s 100-ns
/// TimeSpan truncation — so the merged times are bit-identical to the
/// oracle's and the sequencer's e2e render is frame-aligned at any length.
/// `Duration` appears only at the public boundary (`length`).
///
/// Malformed input THROWS `SwiftySynthError` — never traps the host (the
/// SF2-loader invariant). SMF format 2 is out of scope (spec §2) and is
/// rejected, not implemented.
public final class MidiFile {
    /// The merged messages, time-ordered (ties keep track order).
    let messages: [Message]
    /// Per-message absolute time in seconds (f64, oracle-aligned).
    let times: [Double]

    /// Loads a MIDI file with no loop extension.
    public convenience init(data: Data) throws {
        try self.init(data: data, loopPoint: 0, loopType: .none)
    }

    /// Loads a MIDI file, recognizing the given loop extension's CC markers.
    public convenience init(data: Data, loopType: MidiFileLoopType) throws {
        try self.init(data: data, loopPoint: 0, loopType: loopType)
    }

    /// Loads a MIDI file and inserts a loop start point at the given tick.
    public convenience init(data: Data, loopPoint: Int) throws {
        guard loopPoint >= 0 else {
            throw SwiftySynthError.invalidMidiFile("The loop point must be a non-negative value.")
        }
        try self.init(data: data, loopPoint: loopPoint, loopType: .none)
    }

    public convenience init(url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    public convenience init(url: URL, loopType: MidiFileLoopType) throws {
        try self.init(data: try Data(contentsOf: url), loopType: loopType)
    }

    public convenience init(url: URL, loopPoint: Int) throws {
        try self.init(data: try Data(contentsOf: url), loopPoint: loopPoint)
    }

    /// Mirrors `MidiFile.Load`.
    init(data: Data, loopPoint: Int, loopType: MidiFileLoopType) throws {
        let reader = BinaryReader(data: data)

        let chunkType = try reader.readFourCC()
        guard chunkType == "MThd" else {
            throw SwiftySynthError.invalidMidiFile("The chunk type must be 'MThd', but was '\(chunkType)'.")
        }
        let size = try reader.readInt32BigEndian()
        guard size == 6 else {
            throw SwiftySynthError.invalidMidiFile("The MThd chunk has invalid data.")
        }
        let format = try reader.readInt16BigEndian()
        guard format == 0 || format == 1 else {
            // SMF format 2 (multi-song) is out of scope — spec §2.
            throw SwiftySynthError.invalidMidiFile("The format \(format) is not supported.")
        }
        let trackCount = Int(try reader.readInt16BigEndian())
        let resolution = Int(try reader.readInt16BigEndian())

        var messageLists: [[Message]] = []
        var tickLists: [[Int32]] = []
        messageLists.reserveCapacity(trackCount)
        tickLists.reserveCapacity(trackCount)
        for _ in 0..<trackCount {
            let (messageList, tickList) = try MidiFile.readTrack(reader, loopType)
            messageLists.append(messageList)
            tickLists.append(tickList)
        }

        if loopPoint != 0 {
            // C# indexes track 0 unconditionally; an empty file would crash
            // there — here it throws (never-trap).
            guard let lastTick = tickLists.first?.last else {
                throw SwiftySynthError.invalidMidiFile("The MIDI file has no track to hold the loop point.")
            }
            let loopTick = Int32(clamping: loopPoint)
            if loopTick <= lastTick {
                for i in 0..<tickLists[0].count where tickLists[0][i] >= loopTick {
                    tickLists[0].insert(loopTick, at: i)
                    messageLists[0].insert(.loopStart, at: i)
                    break
                }
            } else {
                tickLists[0].append(loopTick)
                messageLists[0].append(.loopStart)
            }
        }

        (messages, times) = MidiFile.mergeTracks(messageLists, tickLists, resolution)
    }

    /// The length of the MIDI file. `.zero` for a file with no events
    /// (where the C# property would throw — never-trap applies).
    public var length: Duration {
        times.last.map { Duration.seconds($0) } ?? .zero
    }

    /// Mirrors `MidiFile.ReadTrack` — including which paths update the
    /// running-status byte (every explicit-status event, SysEx and meta
    /// included, exactly as the C# does).
    private static func readTrack(
        _ reader: BinaryReader, _ loopType: MidiFileLoopType
    ) throws -> ([Message], [Int32]) {
        let chunkType = try reader.readFourCC()
        guard chunkType == "MTrk" else {
            throw SwiftySynthError.invalidMidiFile("The chunk type must be 'MTrk', but was '\(chunkType)'.")
        }
        let size = try reader.readInt32BigEndian()
        let end = reader.position + Int(size)

        var messages: [Message] = []
        var ticks: [Int32] = []

        var tick: Int32 = 0
        var lastStatus: UInt8 = 0

        while true {
            let delta = try reader.readIntVariableLength()
            let first = try reader.readUInt8()

            let (sum, overflow) = tick.addingReportingOverflow(delta)
            guard !overflow else {
                throw SwiftySynthError.invalidMidiFile("Long MIDI file is not supported.")
            }
            tick = sum

            if (first & 128) == 0 {
                let command = lastStatus & 0xF0
                if command == 0xC0 || command == 0xD0 {
                    messages.append(.common(lastStatus, first))
                    ticks.append(tick)
                } else {
                    let data2 = try reader.readUInt8()
                    messages.append(.common(lastStatus, first, data2, loopType))
                    ticks.append(tick)
                }
                continue
            }

            switch first {
            case 0xF0, 0xF7: // System Exclusive
                try discardData(reader)

            case 0xFF: // Meta Event
                switch try reader.readUInt8() {
                case 0x2F: // End of Track
                    _ = try reader.readUInt8()
                    messages.append(.endOfTrack)
                    ticks.append(tick)
                    // Some MIDI files may have events inserted after the EOT.
                    // Such events should be ignored.
                    if reader.position < end {
                        try reader.skip(end - reader.position)
                    }
                    return (messages, ticks)

                case 0x51: // Tempo
                    messages.append(.tempoChange(try readTempo(reader)))
                    ticks.append(tick)

                default:
                    try discardData(reader)
                }

            default:
                let command = first & 0xF0
                if command == 0xC0 || command == 0xD0 {
                    let data1 = try reader.readUInt8()
                    messages.append(.common(first, data1))
                    ticks.append(tick)
                } else {
                    let data1 = try reader.readUInt8()
                    let data2 = try reader.readUInt8()
                    messages.append(.common(first, data1, data2, loopType))
                    ticks.append(tick)
                }
            }

            lastStatus = first
        }
    }

    /// Mirrors `MidiFile.MergeTracks`. Time accumulates in f64 seconds with
    /// rustysynth's exact operation order (Global Constraints) — do NOT
    /// refactor the arithmetic.
    private static func mergeTracks(
        _ messageLists: [[Message]], _ tickLists: [[Int32]], _ resolution: Int
    ) -> ([Message], [Double]) {
        var mergedMessages: [Message] = []
        var mergedTimes: [Double] = []

        var indices = [Int](repeating: 0, count: messageLists.count)

        var currentTick: Int32 = 0
        var currentTime = 0.0

        var tempo = 120.0

        while true {
            var minTick = Int32.max
            var minIndex = -1
            for ch in 0..<tickLists.count {
                if indices[ch] < tickLists[ch].count {
                    let tick = tickLists[ch][indices[ch]]
                    if tick < minTick {
                        minTick = tick
                        minIndex = ch
                    }
                }
            }

            if minIndex == -1 {
                break
            }

            let nextTick = tickLists[minIndex][indices[minIndex]]
            let deltaTick = nextTick - currentTick
            let deltaTime = 60.0 / (Double(resolution) * tempo) * Double(deltaTick)

            currentTick += deltaTick
            currentTime += deltaTime

            let message = messageLists[minIndex][indices[minIndex]]
            if message.type == .tempoChange {
                tempo = message.tempo
            } else {
                mergedMessages.append(message)
                mergedTimes.append(currentTime)
            }

            indices[minIndex] += 1
        }

        return (mergedMessages, mergedTimes)
    }

    /// Mirrors `MidiFile.ReadTempo`: a tempo meta's payload must be exactly
    /// 3 bytes (µs per quarter note, big-endian).
    private static func readTempo(_ reader: BinaryReader) throws -> Int32 {
        let size = try reader.readIntVariableLength()
        guard size == 3 else {
            throw SwiftySynthError.invalidMidiFile("Failed to read the tempo value.")
        }
        let b1 = Int32(try reader.readUInt8())
        let b2 = Int32(try reader.readUInt8())
        let b3 = Int32(try reader.readUInt8())
        return (b1 << 16) | (b2 << 8) | b3
    }

    /// Mirrors `MidiFile.DiscardData`: length-prefixed payload, skipped.
    private static func discardData(_ reader: BinaryReader) throws {
        let size = try reader.readIntVariableLength()
        try reader.skip(Int(size))
    }
}

extension MidiFile {
    /// One merged event. Mirrors `MidiFile.Message`: the `channel` byte
    /// doubles as the type discriminant for the synthetic kinds (tempo
    /// change / loop markers / end of track — values 252...255).
    struct Message: Equatable {
        let channel: UInt8
        let command: UInt8
        let data1: UInt8
        let data2: UInt8

        static func common(_ status: UInt8, _ data1: UInt8) -> Message {
            Message(channel: status & 0x0F, command: status & 0xF0, data1: data1, data2: 0)
        }

        static func common(
            _ status: UInt8, _ data1: UInt8, _ data2: UInt8, _ loopType: MidiFileLoopType
        ) -> Message {
            let command = status & 0xF0

            if command == 0xB0 {
                switch loopType {
                case .rpgMaker:
                    if data1 == 111 { return .loopStart }

                case .incredibleMachine:
                    if data1 == 110 { return .loopStart }
                    if data1 == 111 { return .loopEnd }

                case .finalFantasy:
                    if data1 == 116 { return .loopStart }
                    if data1 == 117 { return .loopEnd }

                case .none:
                    break
                }
            }

            return Message(channel: status & 0x0F, command: command, data1: data1, data2: data2)
        }

        static func tempoChange(_ tempo: Int32) -> Message {
            Message(
                channel: MessageType.tempoChange.rawValue,
                command: UInt8(truncatingIfNeeded: tempo >> 16),
                data1: UInt8(truncatingIfNeeded: tempo >> 8),
                data2: UInt8(truncatingIfNeeded: tempo))
        }

        static let loopStart = Message(channel: MessageType.loopStart.rawValue, command: 0, data1: 0, data2: 0)
        static let loopEnd = Message(channel: MessageType.loopEnd.rawValue, command: 0, data1: 0, data2: 0)
        static let endOfTrack = Message(channel: MessageType.endOfTrack.rawValue, command: 0, data1: 0, data2: 0)

        var type: MessageType {
            MessageType(rawValue: channel) ?? .normal
        }

        /// Beats per minute from the packed µs-per-quarter-note payload.
        var tempo: Double {
            60_000_000.0 / Double((Int32(command) << 16) | (Int32(data1) << 8) | Int32(data2))
        }
    }

    enum MessageType: UInt8 {
        case normal = 0
        case tempoChange = 252
        case loopStart = 253
        case loopEnd = 254
        case endOfTrack = 255
    }
}
