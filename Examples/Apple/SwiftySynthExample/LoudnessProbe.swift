import Foundation
import SwiftySynth

/// Offline loudness A/B: renders a single sustained note on two GM programs
/// through the SAME SoundFont and reports peak / RMS dBFS, so the per-preset
/// loudness gap (driven by each preset's `initialAttenuation`) can be read as a
/// number instead of judged by ear.
///
/// Motivation: after Folino moved live playback onto SwiftySynth (a MeltySynth
/// port) it faithfully applies each preset's `initialAttenuation`, where the
/// prior AUMIDISynth path effectively normalized preset loudness. On
/// MuseScore_General, `Acoustic Grand Piano` (program 0) carries ~20 dB of
/// attenuation while `Fingered Bass` (program 33) carries 0 dB, so a staff
/// switched to piano drops well below the score's default bass. This probe
/// quantifies that gap and doubles as the tuning harness for any fix.
enum LoudnessProbe {
    struct Result {
        let program: Int
        let key: Int
        let velocity: Int
        let peakDb: Float
        let rmsDb: Float
    }

    /// Render one note offline and measure peak / RMS dBFS over `seconds`.
    /// Reverb/chorus is OFF by default so the number isolates the dry voice gain
    /// (velocity curve + `initialAttenuation`) rather than a wet tail.
    static func measure(
        soundFont: SoundFont, program: Int, key: Int, velocity: Int,
        sampleRate: Int = 44_100, seconds: Double = 1.0, reverbChorus: Bool = false,
        enableModulators: Bool = false,
    ) -> Result? {
        guard let settings = try? SynthesizerSettings(
            sampleRate: sampleRate, maximumPolyphony: 256,
            enableReverbAndChorus: reverbChorus, enableModulators: enableModulators,
        ),
            let synth = try? Synthesizer(soundFont: soundFont, settings: settings)
        else { return nil }
        synth.masterVolume = 1.0 // match SwiftySynthBackend.makeSynth

        // Bank 0 (MSB/LSB) + program change on channel 0, then the note.
        synth.processMidiMessage(channel: 0, command: 0xB0, data1: 0, data2: 0)
        synth.processMidiMessage(channel: 0, command: 0xB0, data1: 32, data2: 0)
        synth.processMidiMessage(channel: 0, command: 0xC0, data1: program, data2: 0)
        synth.noteOn(key: key, velocity: velocity, on: 0)

        let total = Int(Double(sampleRate) * seconds)
        let blockSize = 4096
        var left = [Float](repeating: 0, count: blockSize)
        var right = [Float](repeating: 0, count: blockSize)
        var peak: Float = 0
        var sumSq = 0.0
        var done = 0
        while done < total {
            let count = min(blockSize, total - done)
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    synth.render(
                        left: UnsafeMutableBufferPointer(rebasing: l[0 ..< count]),
                        right: UnsafeMutableBufferPointer(rebasing: r[0 ..< count]),
                    )
                }
            }
            for i in 0 ..< count {
                peak = max(peak, max(abs(left[i]), abs(right[i])))
                sumSq += Double(left[i]) * Double(left[i]) + Double(right[i]) * Double(right[i])
            }
            done += count
        }
        let rms = Float((sumSq / Double(2 * total)).squareRoot())
        return Result(
            program: program, key: key, velocity: velocity,
            peakDb: 20 * log10(max(peak, 1e-9)), rmsDb: 20 * log10(max(rms, 1e-9)),
        )
    }

    /// GM programs to A/B: the score's default (Fingered Bass) vs the switch
    /// users hit (Acoustic Grand Piano).
    static let bassProgram = 33
    static let pianoProgram = 0

    /// Every `*.sf2` bundled under `Sounds/`, so the probe covers whichever
    /// SoundFonts are present (bundled GeneralUser-GS and/or a symlinked
    /// MuseScore_General).
    static func bundledSoundFontURLs() -> [URL] {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Sounds"),
              let items = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: nil,
              )
        else { return [] }
        return items
            .filter { $0.pathExtension.lowercased() == "sf2" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Build a human-readable A/B report across the bundled SoundFonts.
    static func report(
        keys: [Int] = [52, 60, 64, 72], velocities: [Int] = [49, 80, 100],
    ) -> String {
        var out = "=== SwiftySynth Loudness A/B — piano(prog 0) OFF/ON vs bass(prog 33), dry ===\n"
        out += "delta = piano_ON - bass (target ~5 dB, matching FluidSynth)\n"
        let urls = bundledSoundFontURLs()
        if urls.isEmpty { return out + "no SoundFonts found under Sounds/\n" }
        for url in urls {
            out += "\nSoundFont: \(url.lastPathComponent)\n"
            guard let sf = try? SoundFont(url: url) else {
                out += "  (failed to load)\n"; continue
            }
            out += "  key vel |    bass | piano OFF | piano ON |  delta(ON-bass)\n"
            for key in keys {
                for vel in velocities {
                    guard let bass = measure(soundFont: sf, program: bassProgram, key: key, velocity: vel),
                          let pianoOff = measure(soundFont: sf, program: pianoProgram, key: key, velocity: vel),
                          let pianoOn = measure(
                              soundFont: sf, program: pianoProgram, key: key, velocity: vel,
                              enableModulators: true,
                          )
                    else { continue }
                    let delta = pianoOn.peakDb - bass.peakDb
                    out += String(
                        format: "  %3d %3d | %6.1f  |  %6.1f   | %6.1f  | %+6.1f dB\n",
                        key, vel, bass.peakDb, pianoOff.peakDb, pianoOn.peakDb, delta,
                    )
                }
            }
        }
        return out
    }

    /// When launched with `SWIFTYSYNTH_PROBE=1`, print the report to stdout and
    /// exit — lets the report be captured headlessly (`./App SWIFTYSYNTH_PROBE=1`)
    /// without reading the SwiftUI view.
    static func runIfRequestedThenExit() {
        guard ProcessInfo.processInfo.environment["SWIFTYSYNTH_PROBE"] == "1" else { return }
        FileHandle.standardOutput.write(Data(report().utf8))
        exit(0)
    }
}
