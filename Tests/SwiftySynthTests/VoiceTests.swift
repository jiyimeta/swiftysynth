import Foundation
import Testing
@testable import SwiftySynth

/// Hermetic Voice unit tests over the synthetic in-memory font.
///
/// Deterministic premise used throughout (font-independent): every SF2
/// timecents→seconds conversion is 2^(x/1200) > 0, so a voice's volume
/// envelope always has delay > 0 — `start` runs `volEnv.start` → `process(0)`
/// at time 0 < delay, leaving the envelope in the Delay stage with value 0.
/// A freshly started, never-processed voice therefore ALWAYS has priority
/// exactly 4.0 (Delay: 4 + value) and voiceLength 0.
///
/// The looping variant (`sampleModes` generator 54 = 1, continuous) keeps a
/// processed voice alive indefinitely: with all-default envelope generators
/// the volume envelope reaches Decay within 3 blocks and clamps at
/// sustainLevel 1.0 (sustainVolumeEnvelope default 0 dB), so priority is
/// exactly 2.0 (Decay: 1 + value) from then on.
struct VoiceTests {
    private func makeLoopingFont() throws -> SoundFont {
        try SoundFont(data: SyntheticSF2.minimal(instrumentGenerators: [(54, 1), (53, 0)]))
    }

    private func startVoice(
        font: SoundFont, channel: Int, channelInfo: Channel, velocity: Int = 100
    ) -> Voice {
        let presetRegion = font.presets[0].regions[0]
        let instrumentRegion = presetRegion.instrument.regions[0]
        let voice = Voice(sampleRate: 44_100, blockSize: 64)
        voice.start(
            region: RegionPair(preset: presetRegion, instrument: instrumentRegion),
            channel: channel, channelInfo: channelInfo,
            data: font.waveData, key: 60, velocity: velocity)
        return voice
    }

    @Test func freshVoiceCarriesDelayStagePriorityAndItsChannelIndex() throws {
        let font = try makeLoopingFont()
        let voice = startVoice(font: font, channel: 5, channelInfo: Channel(isPercussionChannel: false))
        #expect(voice.priority == 4.0, "Delay stage: priority = 4 + value(0)")
        #expect(voice.voiceLength == 0)
        #expect(voice.channel == 5)
    }

    @Test func killZeroesPriorityAndDiesOnNextProcess() throws {
        let font = try makeLoopingFont()
        let voice = startVoice(font: font, channel: 0, channelInfo: Channel(isPercussionChannel: false))
        voice.kill()
        #expect(voice.priority == 0, "inaudible (noteGain < nonAudible) reads priority 0")
        #expect(voice.process() == false, "a killed voice must die on its next process()")
    }

    @Test func velocityZeroVoiceIsBornInaudible() throws {
        let font = try makeLoopingFont()
        let voice = startVoice(
            font: font, channel: 0, channelInfo: Channel(isPercussionChannel: false), velocity: 0)
        #expect(voice.priority == 0)
    }

    @Test func reverbAndChorusSendsFollowChannelAndClampToUnity() throws {
        let font = try makeLoopingFont()
        let channel = Channel(isPercussionChannel: false)
        let voice = startVoice(font: font, channel: 0, channelInfo: channel)

        channel.setReverbSend(127)   // 1.0 + instrument send (0) → clamped top of [0, 1]
        channel.setChorusSend(64)
        #expect(voice.process())

        #expect(voice.currentReverbSend == 1.0)
        #expect(voice.currentChorusSend == Float(64) / Float(127))
        // First block: previous == current (the voiceLength == 0 double-assign
        // that suppresses the gain ramp on a voice's very first block).
        #expect(voice.previousReverbSend == voice.currentReverbSend)
        #expect(voice.previousChorusSend == voice.currentChorusSend)
    }

    @Test func holdPedalDefersReleaseUntilLifted() throws {
        let font = try makeLoopingFont()
        let channel = Channel(isPercussionChannel: false)
        let voice = startVoice(font: font, channel: 0, channelInfo: channel)

        channel.setHoldPedal(127)
        voice.end()
        // 10 blocks = 640 samples ≫ minimumVoiceDuration (88 @ 44.1 kHz), so
        // without the pedal the release would have engaged; with it held the
        // voice must still be in a sustained stage (priority ≥ 1).
        for _ in 0..<10 {
            #expect(voice.process())
        }
        #expect(voice.priority >= 1.0, "pedal held: release must not engage")

        channel.setHoldPedal(0)
        _ = voice.process()   // release engages this block (may even finish it)
        #expect(voice.priority < 1.0, "pedal lifted: Release priority = current release gain < 1")
    }
}
