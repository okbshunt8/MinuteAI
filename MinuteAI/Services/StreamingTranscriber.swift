import Foundation
import WhisperKit

/// Turns a continuous 16 kHz stream into transcript segments in near real time.
///
/// Whisper is not a streaming model, so the audio since the last finished utterance is transcribed
/// again and again to show provisional text, and committed as a segment once the speaker pauses.
final class StreamingTranscriber: @unchecked Sendable {
    enum Event {
        case provisional(String)
        case final(TranscriptSegment)
        /// The audio between these times could not be transcribed.
        case failed(start: TimeInterval, end: TimeInterval)
    }

    private let kit: WhisperKit
    private let language: String
    private let onEvent: @MainActor (Event) -> Void

    private let lock = NSLock()
    private var buffer: [Float] = []
    /// Index (in samples from the start of the recording) of `buffer[0]`.
    private var bufferStart = 0
    private var finished = false
    private var worker: Task<Void, Never>?

    private static let sampleRate = 16_000
    private static let frame = 320  // 20 ms
    private static let speechThreshold: Float = 0.008
    private static let pauseToCommit = 0.7
    private static let maxUtterance = 18.0

    /// A sound has to last this long without a break to count as a voice (0.16 s). Clicks, taps
    /// and bumps are loud but shorter, and Whisper turns them into confident nonsense.
    private static let minimumVoicedRun = 8

    /// Phrases Whisper tends to invent on silence or noise (they close countless video subtitles).
    private static let hallucinations = [
        "ご視聴ありがとうございました", "チャンネル登録", "ご清聴ありがとうございました",
        "Thank you for watching", "Thanks for watching",
    ]
    /// Its favourite invention is also something people really say, so it is only rejected when
    /// the audio is too short to contain it.
    private static let shortHallucinations: Set<String> = ["ありがとうございました", "ありがとうございます"]
    private static let shortHallucinationLimit = 0.9

    init(kit: WhisperKit, language: String, onEvent: @escaping @MainActor (Event) -> Void) {
        self.kit = kit
        self.language = language
        self.onEvent = onEvent
    }

    func start() {
        worker = Task.detached(priority: .userInitiated) { [self] in await run() }
    }

    func append(_ samples: [Float]) {
        lock.withLock { buffer.append(contentsOf: samples) }
    }

    /// Transcribes whatever is left and waits for the last segment to be delivered.
    func finish() async {
        lock.withLock { finished = true }
        await worker?.value
    }

    private func run() async {
        var lastProvisionalCount = 0
        while true {
            let (samples, start, isLast) = lock.withLock { (buffer, bufferStart, finished) }

            let speech = Self.speechFrames(samples)
            guard Self.hasSustainedSound(speech),
                  let firstSpeech = speech.firstIndex(of: true), let lastSpeech = speech.lastIndex(of: true)
            else {
                // Only silence or short noises: keep a short tail so the start of the next word is not cut off.
                drop(max(0, samples.count - Self.sampleRate / 5))
                if lastProvisionalCount != 0 {
                    lastProvisionalCount = 0
                    await onEvent(.provisional(""))
                }
                if isLast { return }
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }

            let duration = Double(samples.count) / Double(Self.sampleRate)
            let trailingSilence = Double((speech.count - 1 - lastSpeech) * Self.frame) / Double(Self.sampleRate)
            var commitCount: Int?
            if isLast || trailingSilence >= Self.pauseToCommit {
                commitCount = samples.count
            } else if duration >= Self.maxUtterance {
                commitCount = Self.quietestSplit(samples)
            }

            if let commitCount {
                let chunk = Array(samples[..<commitCount])
                let text = await transcribe(chunk)
                let chunkSpeech = Self.speechFrames(chunk)
                let endFrame = (chunkSpeech.lastIndex(of: true) ?? lastSpeech) + 1
                drop(commitCount)
                lastProvisionalCount = 0
                let startTime = Double(start + firstSpeech * Self.frame) / Double(Self.sampleRate)
                let endTime = Double(start + endFrame * Self.frame) / Double(Self.sampleRate)
                if let text, !text.isEmpty {
                    await onEvent(.final(TranscriptSegment(start: startTime, end: endTime, text: text)))
                } else if text == nil {
                    await onEvent(.failed(start: startTime, end: endTime))
                }
                await onEvent(.provisional(""))
                if isLast { return }
                continue
            }

            // Still talking: refresh the provisional text once enough new audio has arrived.
            if duration >= 1.0, samples.count - lastProvisionalCount >= Self.sampleRate * 4 / 5 {
                lastProvisionalCount = samples.count
                // A failed preview is not reported: the same audio is tried again when it is committed.
                if let text = await transcribe(samples) { await onEvent(.provisional(text)) }
            } else {
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func drop(_ count: Int) {
        guard count > 0 else { return }
        lock.withLock {
            buffer.removeFirst(min(count, buffer.count))
            bufferStart += count
        }
    }

    /// Returns nil when the model failed, as opposed to "" when there was nothing to write down.
    private func transcribe(_ samples: [Float]) async -> String? {
        let options = DecodingOptions(
            task: .transcribe,
            language: language == "auto" ? nil : language,
            temperatureFallbackCount: 2,
            usePrefillPrompt: true,
            detectLanguage: language == "auto",
            skipSpecialTokens: true,
            withoutTimestamps: true,
            suppressBlank: true)
        do {
            let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
            let text = results.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            return Self.isLikelyHallucination(text, voiced: Self.voicedDuration(samples)) ? "" : text
        } catch {
            NSLog("MinuteAI: transcription failed: \(error)")
            return nil
        }
    }

    /// Voice activity per 20 ms frame, based on signal energy.
    private static func speechFrames(_ samples: [Float]) -> [Bool] {
        var result: [Bool] = []
        result.reserveCapacity(samples.count / frame)
        var index = 0
        while index + frame <= samples.count {
            var sum: Float = 0
            for i in index..<(index + frame) { sum += samples[i] * samples[i] }
            result.append((sum / Float(frame)).squareRoot() > speechThreshold)
            index += frame
        }
        return result
    }

    /// Whether some sound in the frames lasts long enough to be a voice rather than a click.
    private static func hasSustainedSound(_ frames: [Bool]) -> Bool {
        var run = 0
        for isLoud in frames {
            run = isLoud ? run + 1 : 0
            if run >= minimumVoicedRun { return true }
        }
        return false
    }

    /// Seconds of the samples that are loud enough to be speech.
    private static func voicedDuration(_ samples: [Float]) -> Double {
        Double(speechFrames(samples).filter { $0 }.count * frame) / Double(sampleRate)
    }

    private static func isLikelyHallucination(_ text: String, voiced: Double) -> Bool {
        // Nothing but symbols, e.g. "♪~" for background noise.
        if text.unicodeScalars.allSatisfy({ !CharacterSet.alphanumerics.contains($0) }) { return true }
        if hallucinations.contains(where: { text.contains($0) }) && text.count < 30 { return true }
        let bare = String(String.UnicodeScalarView(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
        return shortHallucinations.contains(bare) && voiced < shortHallucinationLimit
    }

    /// Finds the quietest point in the second half of a long utterance to cut it without splitting a word.
    private static func quietestSplit(_ samples: [Float]) -> Int {
        let window = sampleRate * 3 / 10
        let from = samples.count / 2
        let to = samples.count - sampleRate / 2 - window
        guard to > from else { return samples.count }
        var best = from
        var bestEnergy = Float.greatestFiniteMagnitude
        var index = from
        while index < to {
            var sum: Float = 0
            for i in index..<(index + window) { sum += samples[i] * samples[i] }
            if sum < bestEnergy {
                bestEnergy = sum
                best = index
            }
            index += frame
        }
        return best + window / 2
    }
}
