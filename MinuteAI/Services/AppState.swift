import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    let store: MeetingStore
    let settings: AppSettings
    let whisper: WhisperModelManager
    let llm: LLMModelManager
    let recording: RecordingController
    let player = AudioPlayer()

    var selection: UUID? {
        didSet {
            guard selection != oldValue else { return }
            player.stop()
            noteTargetSegmentID = nil
            selectedNoteID = nil
            focusedSegmentID = nil
        }
    }
    var searchText = ""

    /// Transcript line the next note will be attached to.
    var noteTargetSegmentID: UUID?
    private(set) var selectedNoteID: UUID?
    /// Transcript line highlighted because of the selected note or the note being written.
    private(set) var focusedSegmentID: UUID?
    /// Bumped every time the transcript should scroll to `focusedSegmentID`.
    private(set) var focusRequest = 0

    private(set) var summarizingID: UUID?
    private(set) var summaryStatus = ""
    var summaryError: String?
    @ObservationIgnored private var summaryTask: Task<Void, Never>?

    private(set) var chapteringID: UUID?
    private(set) var chapterStatus = ""
    var chapterError: String?
    @ObservationIgnored private var chapterTask: Task<Void, Never>?

    /// The language model handles one job at a time.
    var isModelBusy: Bool { summarizingID != nil || chapteringID != nil }

    init() {
        let store = MeetingStore()
        let settings = AppSettings()
        let whisper = WhisperModelManager()
        self.store = store
        self.settings = settings
        self.whisper = whisper
        self.llm = LLMModelManager()
        self.recording = RecordingController(store: store, settings: settings, whisper: whisper)
        selection = store.meetings.first?.id
        store.recoverInterruptedRecordings()
    }

    func newMeeting() {
        searchText = ""
        selection = store.create().id
    }

    func deleteMeeting(_ id: UUID) {
        guard recording.meetingID != id, summarizingID != id, chapteringID != id else { return }
        if selection == id {
            player.stop()
            selection = nil
        }
        store.delete(id)
    }

    /// Starts a note about a transcript line: the notes input picks it up and the line is highlighted.
    func startNote(on segment: TranscriptSegment) {
        selectedNoteID = nil
        noteTargetSegmentID = segment.id
        focusedSegmentID = segment.id
    }

    func cancelNoteTarget() {
        if focusedSegmentID == noteTargetSegmentID { focusedSegmentID = nil }
        noteTargetSegmentID = nil
    }

    /// Selects a note and shows where in the transcript it was written. Selecting it again clears the highlight.
    func select(_ note: Note, in meeting: Meeting) {
        if selectedNoteID == note.id {
            selectedNoteID = nil
            focusedSegmentID = nil
            return
        }
        selectedNoteID = note.id
        focusedSegmentID = meeting.segment(for: note)?.id
        if focusedSegmentID != nil { focusRequest += 1 }
    }

    /// The model that will write this meeting's summary: the meeting's own choice if it is still
    /// downloaded, otherwise the default.
    func summaryModelID(for meeting: Meeting) -> String {
        if let choice = meeting.summaryModelChoice, llm.state(choice) == .downloaded { return choice }
        return settings.llmModelID
    }

    func summarize(_ id: UUID) {
        guard !isModelBusy, let meeting = store.meeting(id) else { return }
        summarizingID = id
        summaryStatus = "準備中…"
        summaryError = nil
        let modelID = summaryModelID(for: meeting)
        let events = Summarizer.summarize(
            meeting: meeting, categories: settings.categories,
            modelFolder: LLMModelManager.folder(for: modelID))
        summaryTask = Task {
            do {
                for try await event in events {
                    switch event {
                    case .status(let status): summaryStatus = status
                    case .text(let text):
                        store.update(id) {
                            $0.summary = text
                            $0.summaryModel = modelID
                        }
                    }
                }
            } catch is CancellationError {
            } catch {
                summaryError = error.localizedDescription
            }
            summarizingID = nil
            summaryStatus = ""
        }
    }

    func cancelSummary() {
        summaryTask?.cancel()
    }

    /// Has the language model divide the transcript into chapters. Headings written by hand are kept.
    func generateChapters(_ id: UUID) {
        guard !isModelBusy, let meeting = store.meeting(id) else { return }
        chapteringID = id
        chapterStatus = "準備中…"
        chapterError = nil
        let modelFolder = LLMModelManager.folder(for: summaryModelID(for: meeting))
        chapterTask = Task {
            do {
                let chapters = try await Summarizer.chapters(meeting: meeting, modelFolder: modelFolder) { status in
                    Task { @MainActor [weak self] in
                        if self?.chapteringID == id { self?.chapterStatus = status }
                    }
                }
                try Task.checkCancellation()
                if chapters.isEmpty {
                    chapterError = "章の区切りを見つけられませんでした。"
                } else {
                    store.update(id) { meeting in
                        for index in meeting.segments.indices {
                            let isManual = meeting.segments[index].chapterTitle != nil
                                && meeting.segments[index].chapterIsAuto != true
                            if isManual { continue }
                            let chapter = chapters.first { $0.segmentID == meeting.segments[index].id }
                            meeting.segments[index].chapterTitle = chapter?.title
                            meeting.segments[index].chapterIsAuto = chapter != nil ? true : nil
                        }
                    }
                }
            } catch is CancellationError {
            } catch {
                chapterError = error.localizedDescription
            }
            chapteringID = nil
            chapterStatus = ""
        }
    }

    func cancelChapters() {
        chapterTask?.cancel()
    }

    func willTerminate() {
        recording.stopImmediately()
        store.flush()
    }
}
