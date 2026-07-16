import Foundation
import Testing
@testable import SwiftySynth

/// **G-steal** — the acceptance suite for the AUMIDISynth fix (spec §7):
/// under saturation every noteOn yields a sounding voice (steal-to-play,
/// never drop), and the steal order takes the lowest-priority voice first —
/// inaudible, then the quietest release tails, before any sustained voice.
///
/// Population premises on GeneralUser GS Grand Piano (verified in the spike):
/// 1 panned-mono voice per noteOn on keys 22..<86; sustained voices sit in
/// Attack/Hold/Decay with priority ≥ 1 + value > 1; released voices carry
/// priority = current release gain < 1; killed voices read exactly 0.
///
/// One exception, found while writing this suite: key 61 at velocity 100
/// yields 2 voices, not 1 — the real font's Grand Piano preset has a "Stereo
/// Grand Mellow" velocity layer (keys 51...65, velocity 92...101) whose
/// instrument has two overlapping zones that both cover key 61 (a
/// `Grand Piano-D#3` sample spanning 61...64, and a `Grand Piano-A#3` sample
/// pinned to exactly 61) — a real font-authoring artifact, not a code bug. A
/// full scan of keys 22..<86 at velocity 100 confirmed every other key holds
/// the 1-voice premise. `killedVoicesAreStolenFirst` below avoids key 61 in
/// its population for this reason.
@Suite(.enabled(if: FixtureSF2.exists, "GeneralUser GS not present at the locked path"))
struct VoiceStealingTests {
    private func makeSynth(polyphony: Int) throws -> Synthesizer {
        let font = try SoundFont(url: FixtureSF2.url)
        let settings = try SynthesizerSettings(
            sampleRate: 44_100, maximumPolyphony: polyphony, enableReverbAndChorus: false)
        return try Synthesizer(soundFont: font, settings: settings)
    }

    private func activeKeys(_ synth: Synthesizer, channel: Int? = nil) -> [Int] {
        (0..<synth.voices.activeVoiceCount).compactMap { i in
            let voice = synth.voices[i]
            if let channel, voice.channel != channel {
                return nil
            }
            return voice.key
        }
    }

    /// (a) Zero dropped new notes under saturation.
    @Test func saturatedPoolNeverDropsNewNotes() throws {
        let synth = try makeSynth(polyphony: 8)
        var left = [Float](repeating: 0, count: 8_820)
        var right = [Float](repeating: 0, count: 8_820)

        for key in 60..<68 { synth.noteOn(key: key, velocity: 100, on: 0) }   // exactly fills the pool
        #expect(synth.activeVoiceCount == 8)
        renderInto(synth, &left, &right, 0..<8_820)   // 0.2 s: all voices in sustained stages

        for key in 70..<74 { synth.noteOn(key: key, velocity: 100, on: 0) }   // 4 beyond capacity

        let keys = activeKeys(synth)
        #expect(synth.activeVoiceCount == 8, "steal must keep the pool exactly full — never grow, never drop")
        for key in 70..<74 {
            #expect(keys.contains(key), "new note \(key) was dropped — steal-to-play must guarantee it sounds")
        }
    }

    /// (b) Release tails are stolen before sustained voices. (If a released
    /// tail has already decayed to death by steal time, its slot is simply
    /// free — the assertions below hold on either path, and the sustained
    /// voices must survive on both.)
    @Test func releaseTailsAreStolenBeforeSustainedVoices() throws {
        let synth = try makeSynth(polyphony: 16)
        var left = [Float](repeating: 0, count: 8_820)
        var right = [Float](repeating: 0, count: 8_820)

        for key in 40..<56 { synth.noteOn(key: key, velocity: 100, on: 0) }   // fill 16
        #expect(synth.activeVoiceCount == 16)
        renderInto(synth, &left, &right, 0..<8_820)

        for key in 40..<44 { synth.noteOff(key: key, on: 0) }                 // release 4
        renderInto(synth, &left, &right, 0..<8_820)   // releases engage (well past minimumVoiceDuration)

        for key in 70..<74 { synth.noteOn(key: key, velocity: 100, on: 0) }   // 4 new notes

        let keys = activeKeys(synth)
        for key in 44..<56 {
            #expect(keys.contains(key), "sustained voice \(key) was stolen while release tails were available")
        }
        for key in 70..<74 {
            #expect(keys.contains(key), "new note \(key) must sound")
        }
        for key in 40..<44 {
            #expect(!keys.contains(key), "released voice \(key) must be gone (stolen or fully decayed)")
        }
    }

    /// (c) Inaudible voices are stolen first: all-sound-off (CC 0x78) kills a
    /// channel's voices (priority 0); they leave the pool only on the next
    /// rendered block, so an immediate noteOn must take one of them — and
    /// must NOT touch any sustained voice.
    ///
    /// Uses keys 70..<77 (not 60..<67 as in the other two tests) for the 7
    /// ch0 sustained voices: key 61 falls in the Grand Piano's velocity-92-101
    /// crossfade layer and yields 2 voices at velocity 100 (see the type
    /// doc), which would saturate the pool one voice early and turn the ch1
    /// noteOn below into an unintended steal of its own. 70..76 is clear of
    /// that boundary (verified by a full per-key scan).
    @Test func killedVoicesAreStolenFirst() throws {
        let synth = try makeSynth(polyphony: 8)
        var left = [Float](repeating: 0, count: 4_410)
        var right = [Float](repeating: 0, count: 4_410)

        for key in 70..<77 { synth.noteOn(key: key, velocity: 100, on: 0) }   // 7 sustained on ch0
        synth.noteOn(key: 50, velocity: 100, on: 1)                           // 1 on ch1
        #expect(synth.activeVoiceCount == 8)
        renderInto(synth, &left, &right, 0..<4_410)

        synth.processMidiMessage(channel: 1, command: 0xB0, data1: 0x78, data2: 0)  // all sound off, ch1

        synth.noteOn(key: 80, velocity: 100, on: 0)   // deliberately NO render in between

        let ch0Keys = activeKeys(synth, channel: 0)
        #expect(ch0Keys.contains(80), "the new note must sound")
        for key in 70..<77 {
            #expect(ch0Keys.contains(key), "sustained ch0 voice \(key) was stolen while a killed voice was available")
        }
        #expect(activeKeys(synth, channel: 1).isEmpty, "the killed ch1 voice must be the steal victim")
        #expect(synth.activeVoiceCount == 8)
    }
}
