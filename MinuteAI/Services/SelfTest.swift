#if DEBUG
import AVFoundation
import Foundation

/// Developer check of the transcription and summary pipeline without microphone or UI:
/// `MINUTEAI_SELFTEST=/path/to/audio.wav MinuteAI.app/Contents/MacOS/MinuteAI`
/// Feeds the file through the same code path as a live recording, then summarizes the result.
@MainActor
enum SelfTest {
    static func runIfRequested(_ app: AppState) {
        if let path = ProcessInfo.processInfo.environment["MINUTEAI_SELFTEST_CHAPTERS"] {
            Task {
                do {
                    try await chapters(app, meetingJSON: URL(fileURLWithPath: path))
                    exit(0)
                } catch {
                    print("SELFTEST FAILED: \(error)")
                    exit(1)
                }
            }
            return
        }
        guard let path = ProcessInfo.processInfo.environment["MINUTEAI_SELFTEST"] else { return }
        Task {
            do {
                try await run(app, audio: URL(fileURLWithPath: path))
                exit(0)
            } catch {
                print("SELFTEST FAILED: \(error)")
                exit(1)
            }
        }
    }

    /// Chapter generation only, on a saved meeting.json:
    /// `MINUTEAI_SELFTEST_CHAPTERS=/path/to/meeting.json MinuteAI.app/Contents/MacOS/MinuteAI`
    private static func chapters(_ app: AppState, meetingJSON: URL) async throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meeting = try decoder.decode(Meeting.self, from: Data(contentsOf: meetingJSON))
        let start = Date()
        let chapters = try await Summarizer.chapters(
            meeting: meeting, modelFolder: LLMModelManager.folder(for: app.settings.llmModelID)) { print("status: \($0)") }
        for chapter in chapters {
            let line = meeting.segments.firstIndex { $0.id == chapter.segmentID }.map { $0 + 1 } ?? 0
            print("chapter at line \(line): \(chapter.title)")
        }
        print("\(chapters.count) chapters for \(meeting.segments.count) lines in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
    }

    private static func run(_ app: AppState, audio: URL) async throws {
        let variant = app.settings.whisperVariant
        if app.whisper.state(variant) == .notDownloaded { app.whisper.download(variant) }
        while case .downloading(let fraction) = app.whisper.state(variant) {
            print("whisper download \(Int(fraction * 100))%")
            try await Task.sleep(for: .seconds(5))
        }
        guard app.whisper.state(variant) == .downloaded else {
            throw NSError(domain: "SelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: app.whisper.lastError ?? "?"])
        }

        var loadStart = Date()
        let kit = try await app.whisper.load(variant)
        print("whisper loaded in \(String(format: "%.1f", Date().timeIntervalSince(loadStart)))s")

        let file = try AVAudioFile(forReading: audio)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = MonoResampler(sampleRate: AudioRecorder.transcriptionSampleRate).convert(buffer)
        print("audio: \(String(format: "%.1f", Double(samples.count) / 16_000))s")

        var meeting = Meeting(title: "セルフテスト")
        let begin = Date()
        let transcriber = StreamingTranscriber(kit: kit, language: app.settings.language) { event in
            let at = String(format: "%5.1f", Date().timeIntervalSince(begin))
            switch event {
            case .provisional(let text):
                if !text.isEmpty { print("[\(at)s] ... \(text)") }
            case .final(let segment):
                print("[\(at)s] FINAL \(formatTime(segment.start))-\(formatTime(segment.end)) \(segment.text)")
                meeting.segments.append(segment)
            }
        }
        transcriber.start()
        // Deliver the audio at real-time speed, like a live recording.
        var index = 0
        while index < samples.count {
            let end = min(index + 1600, samples.count)
            transcriber.append(Array(samples[index..<end]))
            index = end
            try await Task.sleep(for: .milliseconds(100))
        }
        await transcriber.finish()
        print("segments: \(meeting.segments.count)")

        guard ProcessInfo.processInfo.environment["MINUTEAI_SELFTEST_SUMMARY"] != nil else { return }
        let modelID = app.settings.llmModelID
        if app.llm.state(modelID) == .notDownloaded { app.llm.download(modelID) }
        while case .downloading(let fraction) = app.llm.state(modelID) {
            print("llm download \(Int(fraction * 100))%")
            try await Task.sleep(for: .seconds(10))
        }
        guard app.llm.state(modelID) == .downloaded else {
            throw NSError(domain: "SelfTest", code: 2, userInfo: [NSLocalizedDescriptionKey: app.llm.lastError ?? "?"])
        }
        if !meeting.segments.isEmpty { meeting.segments[meeting.segments.count / 2].marker = .yellow }
        meeting.notes = [
            Note(time: 5, categoryID: NoteCategory.taskID, text: "田中さんが見積もりを金曜までに再提出"),
            Note(time: 12, categoryID: "issue", text: "テスト環境の不足"),
        ]
        let chapters = try await Summarizer.chapters(
            meeting: meeting, modelFolder: LLMModelManager.folder(for: modelID)) { print("status: \($0)") }
        for chapter in chapters {
            let line = meeting.segments.firstIndex { $0.id == chapter.segmentID }.map { $0 + 1 } ?? 0
            print("chapter at line \(line): \(chapter.title)")
        }
        loadStart = Date()
        var summary = ""
        for try await event in Summarizer.summarize(
            meeting: meeting, categories: app.settings.categories, modelFolder: LLMModelManager.folder(for: modelID))
        {
            switch event {
            case .status(let status): print("status: \(status)")
            case .text(let text): summary = text
            }
        }
        print("summary in \(String(format: "%.1f", Date().timeIntervalSince(loadStart)))s:\n\(summary)")
    }
}
#endif
