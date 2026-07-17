/// SF2 modulators (`pmod`/`imod`): size-validated and DISCARDED.
///
/// Ported from `Modulator.cs` (MeltySynth, MIT License — see NOTICE).
/// Discarding is the canonical behavior this port deliberately mirrors
/// (full-port spec §2): MeltySynth does not apply SF2 modulators — its
/// fidelity comes from generator handling plus the reverb/chorus bus — and
/// neither do this port's oracles, so applying them here would diverge
/// from every committed equivalence vector.
enum Modulator {
    /// Mirrors `Modulator.DiscardData`: each modulator record is 10 bytes;
    /// a chunk size that is not a whole number of records is structurally
    /// invalid (thrown, never trapped), otherwise the chunk is skipped.
    static func discardData(reader: BinaryReader, size: Int) throws {
        guard size % 10 == 0 else {
            throw SwiftySynthError.invalidSoundFont("The modulator list is invalid.")
        }
        try reader.skip(size)
    }
}
