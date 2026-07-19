import Foundation

/// Finds the SoundFont and the bundled sample MIDI at runtime.
enum ResourceLocator {
    /// SoundFont resolution: `Sounds/GeneralUser-GS.sf2` in the bundle → any
    /// `*.sf2` in the bundle's `Sounds/` folder → `SWIFTYSYNTH_SF2` env → nil.
    static func soundFontURL() -> URL? {
        if let url = Bundle.main.url(
            forResource: "GeneralUser-GS", withExtension: "sf2", subdirectory: "Sounds") {
            return url
        }
        if let sounds = Bundle.main.resourceURL?.appendingPathComponent("Sounds"),
           let items = try? FileManager.default.contentsOfDirectory(
               at: sounds, includingPropertiesForKeys: nil),
           let sf2 = items.first(where: { $0.pathExtension.lowercased() == "sf2" }) {
            return sf2
        }
        if let env = ProcessInfo.processInfo.environment["SWIFTYSYNTH_SF2"],
           !env.isEmpty, FileManager.default.fileExists(atPath: env) {
            return URL(fileURLWithPath: env)
        }
        return nil
    }

    /// The bundled sample MIDI (folder ref `Resources/Midi/`).
    static func sampleMidiURL() -> URL? {
        Bundle.main.url(forResource: "midi-gm-song", withExtension: "mid", subdirectory: "Midi")
            ?? Bundle.main.url(forResource: "midi-gm-song", withExtension: "mid")
    }
}
