/// The SF2 sample-link type stored in `SampleHeader.sampleType`
/// (SFSampleLink, SoundFont spec §7.10).
///
/// Ported from `SampleType.cs` (MeltySynth, MIT License — see NOTICE) —
/// `internal` there and internal here (full-port spec §2 peripherals): the
/// synthesis path never branches on it (stereo pairs play as two
/// independent panned voices), so it is decode vocabulary, not public API.
/// The raw wire value stays available as `SampleHeader.sampleType`.
enum SampleType: Int32 {
    case mono = 1
    case right = 2
    case left = 4
    case linked = 8
    case romMono = 0x8001
    case romRight = 0x8002
    case romLeft = 0x8004
    case romLinked = 0x8008
}

extension SampleHeader {
    /// The decoded sample type, or `nil` when the raw field holds a value
    /// outside the SFSampleLink vocabulary — garbage file data must never
    /// trap (the loader-wide invariant), and C# would carry the same
    /// unknown value silently in its unchecked enum cast.
    var type: SampleType? { SampleType(rawValue: sampleType) }
}
