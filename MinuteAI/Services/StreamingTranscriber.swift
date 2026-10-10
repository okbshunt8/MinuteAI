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

    /// Phrases Whisper tends to invent on silence or noise.
    private static let hallucinations = [
        "ご視聴ありがとうございました", "チャンネル登録", "ご清聴ありがとうございました",
        "Thank you for watching", "Thanks for watching",
    ]

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
            guard let firstSpeech = speech.firstIndex(of: true), let lastSpeech = speech.lastIndex(of: true) else {
                // Only silence: keep a short tail so the start of the next word is not cut off.
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
                if !text.isEmpty {
                    let segment = TranscriptSegment(
                        start: Double(start + firstSpeech * Self.frame) / Double(Self.sampleRate),
                        end: Double(start + endFrame * Self.frame) / Double(Self.sampleRate),
                        text: text)
                    await onEvent(.final(segment))
                }
                await onEvent(.provisional(""))
                if isLast { return }
                continue
            }

            // Still talking: refresh the provisional text once enough new audio has arrived.
            if duration >= 1.0, samples.count - lastProvisionalCount >= Self.sampleRate * 4 / 5 {
                lastProvisionalCount = samples.count
                let text = await transcribe(samples)
                await onEvent(.provisional(text))
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

    private func transcribe(_ samples: [Float]) async -> String {
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
            if Self.hallucinations.contains(where: { text.contains($0) }) && text.count < 30 { return "" }
            return text
        } catch {
            NSLog("MinuteAI: transcription failed: \(error)")
            return ""
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
