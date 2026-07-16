import Foundation

/// The dynamic voice pool: allocation, exclusive-class reuse, and — when the
/// pool is full — priority-based stealing. This is the AUMIDISynth fix:
/// `requestNew` NEVER fails, so a new note always gets a voice
/// (steal-to-play), and the steal victim is always the lowest-priority voice
/// (inaudible first, then the quietest release tails) — never an audible
/// sustained voice while a better candidate exists.
///
/// Ported from `VoiceCollection.cs` (MeltySynth, MIT License — see NOTICE).
/// The pool STRUCTURE is idiomatic Swift: an owned `[Voice]` constructed from
/// `(sampleRate:blockSize:)` — no `Synthesizer` back-reference (the
/// established retain-cycle-avoiding adaptation), no C# enumerator (callers
/// index the active prefix `0..<activeVoiceCount`). The steal SELECTION in
/// `requestNew` and the swap compaction in `process()` are FAITHFUL
/// transliterations: the selection is the G-steal acceptance criterion, and
/// the compaction order determines the active-prefix order and therefore the
/// FP summation order of the mix that the PCM gates pin.
final class VoiceCollection {
    /// `var` only for `swapAt` in `process()`; the array's size and element
    /// identities are fixed at init — the render path never allocates.
    private var voices: [Voice]

    /// The active voices are exactly the prefix `voices[0..<activeVoiceCount]`.
    private(set) var activeVoiceCount: Int = 0

    /// `maximumPolyphony` must be ≥ 1 (`SynthesizerSettings` guarantees ≥ 8);
    /// every `Voice` — including its per-voice render block — is allocated
    /// here, at init (RT requirement, spec §8).
    init(sampleRate: Int, blockSize: Int, maximumPolyphony: Int) {
        // `requestNew`'s steal path seeds its candidate from `voices[0]`, which assumes a
        // non-empty pool; `SynthesizerSettings` already guarantees `maximumPolyphony >= 8`,
        // so this is defense-in-depth for any other caller constructing this type directly.
        precondition(maximumPolyphony >= 1, "maximumPolyphony must be >= 1")
        var voices: [Voice] = []
        voices.reserveCapacity(maximumPolyphony)
        for _ in 0..<maximumPolyphony {
            voices.append(Voice(sampleRate: sampleRate, blockSize: blockSize))
        }
        self.voices = voices
    }

    /// Mirrors `VoiceCollection.RequestNew`, all three branches, in order:
    /// 1. a voice with the same non-zero exclusive class on the same channel
    ///    is reused (region-authored "choke", e.g. closed/open hi-hat);
    /// 2. else a free pool slot;
    /// 3. else — pool full — the LOWEST-priority voice is stolen, ties broken
    ///    by the LONGER (older) `voiceLength`, full ties by scan order.
    /// Unlike C#'s nullable return (vacuously non-nil for any pool ≥ 1), this
    /// port returns non-optional: a new note ALWAYS gets a voice. The spike's
    /// `//SPIKE: pool-exhaust skip` deviation is gone.
    func requestNew(region: InstrumentRegion, channel: Int) -> Voice {
        let exclusiveClass = region.exclusiveClass
        if exclusiveClass != 0 {
            for i in 0..<activeVoiceCount {
                let voice = voices[i]
                if voice.exclusiveClass == exclusiveClass && voice.channel == channel {
                    return voice
                }
            }
        }

        if activeVoiceCount < voices.count {
            let free = voices[activeVoiceCount]
            activeVoiceCount += 1
            return free
        }

        // Too many active voices... steal the lowest priority. FAITHFUL:
        // strict `<` on priority (first-scanned wins a full tie) and strict
        // `>` on voiceLength (the older voice wins a priority tie). The
        // `voices[0]` seed is only a non-optional placeholder — the first
        // iteration always replaces it (any priority < .greatestFiniteMagnitude).
        var candidate = voices[0]
        var lowestPriority = Float.greatestFiniteMagnitude
        for i in 0..<activeVoiceCount {
            let voice = voices[i]
            let priority = voice.priority
            if priority < lowestPriority {
                lowestPriority = priority
                candidate = voice
            } else if priority == lowestPriority {
                if voice.voiceLength > candidate.voiceLength {
                    candidate = voice
                }
            }
        }
        return candidate
    }

    /// Mirrors `VoiceCollection.Process`: advances every active voice one
    /// block; a dead voice is removed in O(1) by swapping the LAST active
    /// voice into its slot (and re-examining that slot). FAITHFUL — the swap
    /// direction fixes the active-prefix order the mix loop sums in.
    func process() {
        var i = 0

        while true {
            if i == activeVoiceCount {
                return
            }

            if voices[i].process() {
                i += 1
            } else {
                activeVoiceCount -= 1
                voices.swapAt(i, activeVoiceCount)
            }
        }
    }

    /// Mirrors `VoiceCollection.Clear`.
    func clear() {
        activeVoiceCount = 0
    }

    subscript(index: Int) -> Voice {
        voices[index]
    }
}
