import Foundation
import Testing
@testable import SwiftySynth

/// Hermetic VoiceCollection unit tests over the synthetic in-memory font.
/// See VoiceTests for the two deterministic envelope premises used here:
/// fresh (never-processed) voices are ALWAYS Delay-stage priority 4.0 with
/// voiceLength 0; processed looping-region voices settle at exactly
/// priority 2.0 (Decay clamped at sustainLevel 1.0) and never die.
struct VoiceCollectionTests {
    private func makeLoopingFont() throws -> SoundFont {
        try SoundFont(data: SyntheticSF2.minimal(instrumentGenerators: [(54, 1), (53, 0)]))
    }

    private func region(of font: SoundFont) -> InstrumentRegion {
        font.presets[0].regions[0].instrument.regions[0]
    }

    @discardableResult
    private func startVoice(
        _ collection: VoiceCollection, _ font: SoundFont,
        channel: Int, channelInfo: Channel, key: Int
    ) -> Voice {
        let presetRegion = font.presets[0].regions[0]
        let instrumentRegion = presetRegion.instrument.regions[0]
        let voice = collection.requestNew(region: instrumentRegion, channel: channel)
        voice.start(
            region: RegionPair(preset: presetRegion, instrument: instrumentRegion),
            channel: channel, channelInfo: channelInfo,
            data: font.waveData, key: key, velocity: 100)
        return voice
    }

    @Test func freeSlotsAreHandedOutUntilCapacity() throws {
        let font = try makeLoopingFont()
        let collection = VoiceCollection(sampleRate: 44_100, blockSize: 64, maximumPolyphony: 8)
        let channel = Channel(isPercussionChannel: false)
        var distinct = Set<ObjectIdentifier>()
        for key in 60..<68 {
            distinct.insert(ObjectIdentifier(
                startVoice(collection, font, channel: 0, channelInfo: channel, key: key)))
        }
        #expect(collection.activeVoiceCount == 8)
        #expect(distinct.count == 8, "each allocation below capacity must be a distinct voice")
    }

    @Test func exclusiveClassReusesSameChannelVoiceOnly() throws {
        // exclusiveClass generator (57) = 1 + continuous loop + sampleID terminator.
        let font = try SoundFont(
            data: SyntheticSF2.minimal(instrumentGenerators: [(57, 1), (54, 1), (53, 0)]))
        let instrumentRegion = region(of: font)
        #expect(instrumentRegion.exclusiveClass == 1)

        let collection = VoiceCollection(sampleRate: 44_100, blockSize: 64, maximumPolyphony: 8)
        let first = startVoice(
            collection, font, channel: 0, channelInfo: Channel(isPercussionChannel: false), key: 60)

        let sameChannel = collection.requestNew(region: instrumentRegion, channel: 0)
        #expect(sameChannel === first, "same exclusive class on the same channel reuses the sounding voice (choke)")
        #expect(collection.activeVoiceCount == 1, "reuse must not consume a new slot")

        let otherChannel = collection.requestNew(region: instrumentRegion, channel: 1)
        #expect(otherChannel !== first, "a different channel must NOT reuse the exclusive-class voice")
        #expect(collection.activeVoiceCount == 2)
    }

    @Test func deadVoicesAreSwapRemovedByProcess() throws {
        // Default (no-loop) region: the 8-frame synthetic sample is exhausted
        // inside the first 64-frame block, but per Oscillator.fillBlockNoLoop
        // (Task 5) exhaustion mid-block still returns true (zero-padding the
        // rest of the block) — the voice only reports dead (false) on the
        // NEXT process() call, where `index >= end` already holds at t == 0.
        // So the pool needs two process() rounds to fully compact away.
        let font = try SoundFont(data: SyntheticSF2.minimal())
        let collection = VoiceCollection(sampleRate: 44_100, blockSize: 64, maximumPolyphony: 8)
        let channel = Channel(isPercussionChannel: false)
        for key in 60..<63 {
            startVoice(collection, font, channel: 0, channelInfo: channel, key: key)
        }
        #expect(collection.activeVoiceCount == 3)
        collection.process()
        #expect(collection.activeVoiceCount == 3, "sample exhaustion mid-block still returns true this round")
        collection.process()
        #expect(collection.activeVoiceCount == 0, "voices whose sample ran out must be compacted away")
    }

    @Test func fullPoolStealsTheLowestPriorityVoice() throws {
        let font = try makeLoopingFont()
        let collection = VoiceCollection(sampleRate: 44_100, blockSize: 64, maximumPolyphony: 8)
        let channel = Channel(isPercussionChannel: false)
        var started = [Voice]()
        for key in 60..<68 {
            started.append(startVoice(collection, font, channel: 0, channelInfo: channel, key: key))
        }
        // All 8 sit at Delay priority 4.0; kill one → priority 0.
        started[3].kill()
        let stolen = collection.requestNew(region: region(of: font), channel: 0)
        #expect(stolen === started[3], "the inaudible (killed) voice must be the steal candidate")
        #expect(collection.activeVoiceCount == 8, "stealing must not change the active count")
    }

    @Test func fullTieStealsTheFirstScannedVoice() throws {
        let font = try makeLoopingFont()
        let collection = VoiceCollection(sampleRate: 44_100, blockSize: 64, maximumPolyphony: 8)
        let channel = Channel(isPercussionChannel: false)
        var started = [Voice]()
        for key in 60..<68 {
            started.append(startVoice(collection, font, channel: 0, channelInfo: channel, key: key))
        }
        // Full tie: priority 4.0 AND voiceLength 0 everywhere. The faithful
        // loop (strict `<` on priority, strict `>` on voiceLength) keeps the
        // FIRST-scanned voice; a `<=`/`>=` drift would select the last one.
        let stolen = collection.requestNew(region: region(of: font), channel: 0)
        #expect(stolen === started[0])
    }

    @Test func equalPriorityTieStealsTheOlderVoice() throws {
        let font = try makeLoopingFont()
        let collection = VoiceCollection(sampleRate: 44_100, blockSize: 64, maximumPolyphony: 8)
        let channel = Channel(isPercussionChannel: false)
        var started = [Voice]()
        for key in 60..<68 {
            started.append(startVoice(collection, font, channel: 0, channelInfo: channel, key: key))
        }
        // Advance two voices individually into the sustain-clamped Decay
        // stage — both then read priority EXACTLY 2.0 — with the OLDER
        // (longer voiceLength) one at the LATER index, so only the tie-break
        // branch (`voiceLength > candidate.voiceLength`) can select it.
        for _ in 0..<10 { _ = started[2].process() }   // priority 2.0, voiceLength 640
        for _ in 0..<20 { _ = started[5].process() }   // priority 2.0, voiceLength 1280 (older)
        #expect(started[2].priority == 2.0)
        #expect(started[5].priority == 2.0)
        #expect(started[5].voiceLength > started[2].voiceLength)

        let stolen = collection.requestNew(region: region(of: font), channel: 0)
        #expect(stolen === started[5], "among equal priorities the older (longer voiceLength) voice is stolen")
    }

    @Test func clearResetsTheActiveCount() throws {
        let font = try makeLoopingFont()
        let collection = VoiceCollection(sampleRate: 44_100, blockSize: 64, maximumPolyphony: 8)
        let channel = Channel(isPercussionChannel: false)
        for key in 60..<64 {
            startVoice(collection, font, channel: 0, channelInfo: channel, key: key)
        }
        #expect(collection.activeVoiceCount == 4)
        collection.clear()
        #expect(collection.activeVoiceCount == 0)
    }
}
