import Foundation

enum MachTime {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func toNanos(_ delta: UInt64) -> UInt64 {
        delta * UInt64(timebase.numer) / UInt64(timebase.denom)
    }
}
