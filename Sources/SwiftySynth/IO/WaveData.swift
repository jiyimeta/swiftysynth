import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

/// A SoundFont's 16-bit sample pool (the `smpl` chunk), read in place.
///
/// Not an `[Int16]`: a General-MIDI font's pool is most of the file — about 200 MB for MuseScore_General — and copying
/// it into an array made every sample dirty memory for as long as the font was loaded, whether or not a single note of
/// it ever sounded. A font loaded from a file (`SoundFont(url:)`) is instead read straight out of a read-only mapping
/// of that file: the system pages in only the samples a voice actually reads, and those pages are clean, so they never
/// count toward the process's memory footprint and can be dropped under pressure and read back. A font loaded from
/// `Data` (`SoundFont(data:)`) holds its own copy of the bytes, as before.
///
/// Immutable once built, and the storage it reads is kept alive by the value itself, so it can be shared across
/// threads and voices freely.
public struct WaveData: RandomAccessCollection, @unchecked Sendable {
    /// Keeps the memory `base` points into alive: a `MappedFile` or a `ByteBuffer`.
    let owner: AnyObject?
    let base: UnsafePointer<Int16>?
    public let count: Int

    init(owner: AnyObject?, base: UnsafePointer<Int16>?, count: Int) {
        self.owner = owner
        self.base = base
        self.count = count
    }

    static let empty = WaveData(owner: nil, base: nil, count: 0)

    /// A pool holding its own copy of `samples`.
    init(copying samples: [Int16]) {
        let buffer = samples.withUnsafeBytes { ByteBuffer(copying: $0) }
        let base = buffer.bytes.baseAddress.map { $0.bindMemory(to: Int16.self, capacity: samples.count) }
        self.init(owner: buffer, base: base, count: samples.count)
    }

    public var startIndex: Int { 0 }
    public var endIndex: Int { count }

    /// Bounds-checked like `Array`'s subscript, so an index a malformed font slips past the load-time checks traps
    /// here exactly as it did with the array, rather than reading outside the pool.
    @inline(__always)
    public subscript(position: Int) -> Int16 {
        precondition(position >= 0 && position < count, "WaveData index out of range")
        return base.unsafelyUnwrapped[position]
    }

    /// Whether the samples are read in place from a file mapping (`SoundFont(url:)`), rather than held in memory the
    /// process owns.
    public var isMemoryMapped: Bool {
        owner is MappedFile
    }

    /// Asks the system to read `range` of the pool in now, and touches every page of it, so a voice that later reads
    /// those samples does not take the page faults on the audio render thread. Nothing to do for an owned pool, whose
    /// pages are already resident. Call it off the render thread.
    func prefetch(_ range: Range<Int>) {
        guard owner is MappedFile, let base else { return }
        let lower = Swift.max(0, range.lowerBound)
        let upper = Swift.min(count, range.upperBound)
        guard lower < upper else { return }
        let pageSize = Int(getpagesize())
        let start = UInt(bitPattern: UnsafeRawPointer(base + lower)) & ~UInt(pageSize - 1)
        let end = UInt(bitPattern: UnsafeRawPointer(base + upper))
        guard let pageStart = UnsafeRawPointer(bitPattern: start) else { return }
        let length = Int(end - start)
        #if canImport(Darwin) || canImport(Glibc) || canImport(Android)
        _ = madvise(UnsafeMutableRawPointer(mutating: pageStart), length, MADV_WILLNEED)
        #endif
        var sum: UInt8 = 0
        var offset = 0
        while offset < length {
            sum &+= pageStart.load(fromByteOffset: offset, as: UInt8.self)
            offset += pageSize
        }
        keepAlive(sum)
    }
}

/// Opaque to the optimizer, so the page reads in `WaveData.prefetch` — whose values nothing else uses — are not
/// dropped.
@inline(never) @_optimize(none)
private func keepAlive(_: UInt8) {}

/// Bytes the process owns, for a font parsed from `Data`. 16-byte aligned, so a sample pool at an even offset inside
/// it can be read as `Int16` in place.
final class ByteBuffer {
    private let storage: UnsafeMutableRawBufferPointer
    let bytes: UnsafeRawBufferPointer

    init(copying raw: UnsafeRawBufferPointer) {
        storage = UnsafeMutableRawBufferPointer.allocate(byteCount: Swift.max(raw.count, 1), alignment: 16)
        if raw.count > 0 {
            storage.copyMemory(from: raw)
        }
        bytes = UnsafeRawBufferPointer(start: storage.baseAddress, count: raw.count)
    }

    convenience init(copying data: Data) {
        self.init(copying: data.withUnsafeBytes { UnsafeRawBufferPointer($0) })
    }

    deinit {
        storage.deallocate()
    }
}

/// A read-only, private mapping of a whole file, unmapped when the last reader lets go. Only built where the platform
/// has `mmap`; elsewhere `SoundFont(url:)` reads the file into a `ByteBuffer` instead.
final class MappedFile {
    let bytes: UnsafeRawBufferPointer

    /// Nil when the file cannot be opened or mapped — including an empty file, which `mmap` refuses — so the caller
    /// can fall back to reading it.
    init?(url: URL) {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Android)
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_size > 0 else { return nil }
        let length = Int(status.st_size)
        guard let address = mmap(nil, length, PROT_READ, MAP_PRIVATE, descriptor, 0),
              address != UnsafeMutableRawPointer(bitPattern: -1)
        else { return nil }
        bytes = UnsafeRawBufferPointer(start: address, count: length)
        #else
        return nil
        #endif
    }

    deinit {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Android)
        if let address = bytes.baseAddress {
            munmap(UnsafeMutableRawPointer(mutating: address), bytes.count)
        }
        #endif
    }
}
