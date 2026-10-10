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
            relinkingNoteID = nil
            selectedNoteID = nil
            currentSegmentID = nil
        }
    }
    var searchText = ""

    /// Transcript line the next note will be attached to.
    var noteTargetSegmentID: UUID?
    /// The one "current position" shared by the transcript, the notes and the player: selecting a
    /// note, selecting a transcript line or moving the playback position all set it, and the other
    /// two follow.
    private(set) var currentSegmentID: UUID?
    /// What last moved the current position.
    private(set) var selectionSource = SelectionSource.transcript
    /// Note that was clicked. Only needed for notes that belong to no transcript line.
    private(set) var selectedNoteID: UUID?
    /// Note waiting for a transcript line to be picked as its new place.
    private(set) var relinkingNoteID: UUID?
    /// Bumped when the transcript / the notes list should scroll to the current position.
    private(set) var transcriptScrollRequest = 0
    private(set) var notesScrollRequest = 0

    enum SelectionSource {
        case note, transcript, playback
    }

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
        currentSegmentID = segment.id
        selectionSource = .transcript
    }

    func cancelNoteTarget() {
        noteTargetSegmentID = nil
    }

    /// Selects a note: the transcript line it belongs to becomes the current position and the
    /// player moves there. Selecting it again clears the selection.
    func select(_ note: Note, in meeting: Meeting) {
        if selectedNoteID == note.id {
            selectedNoteID = nil
            currentSegmentID = nil
            return
        }
        selectedNoteID = note.id
        selectionSource = .note
        let segment = meeting.segment(for: note)
        currentSegmentID = segment?.id
        if let segment {
            transcriptScrollRequest += 1
            movePlayer(to: segment, in: meeting)
        }
    }

    /// The next transcript line that is selected becomes this note's place.
    func startRelinking(_ note: Note) {
        relinkingNoteID = note.id
        selectedNoteID = note.id
    }

    func cancelRelinking() {
        relinkingNoteID = nil
    }

    /// Detaches a note from the transcript; it then sorts after the notes that have a position.
    func unlink(_ note: Note, in meeting: Meeting) {
        store.update(meeting.id) { meeting in
            guard let index = meeting.notes.firstIndex(where: { $0.id == note.id }) else { return }
            meeting.notes[index].segmentID = nil
            meeting.notes[index].time = nil
        }
        if selectedNoteID == note.id { currentSegmentID = nil }
    }

    /// A transcript line was selected: its notes become selected and the player moves there.
    func select(_ segment: TranscriptSegment, in meeting: Meeting) {
        if let noteID = relinkingNoteID {
            // The line was picked as the new place of a note.
            relinkingNoteID = nil
            store.update(meeting.id) { meeting in
                guard let index = meeting.notes.firstIndex(where: { $0.id == noteID }) else { return }
                meeting.notes[index].segmentID = segment.id
                meeting.notes[index].time = segment.start
            }
            selectedNoteID = noteID
            selectionSource = .transcript
            currentSegmentID = segment.id
            notesScrollRequest += 1
            movePlayer(to: segment, in: meeting)
            return
        }
        selectedNoteID = nil
        selectionSource = .transcript
        if currentSegmentID != segment.id {
            currentSegmentID = segment.id
            notesScrollRequest += 1
        }
        movePlayer(to: segment, in: meeting)
    }

    /// The playback position moved onto another transcript line (playing, or dragging the slider).
    func playbackMoved(to segmentID: UUID?) {
        guard let segmentID, segmentID != currentSegmentID else { return }
        selectedNoteID = nil
        selectionSource = .playback
        currentSegmentID = segmentID
        transcriptScrollRequest += 1
        notesScrollRequest += 1
    }

    /// Whether the note belongs to the current position.
    func isHighlighted(_ note: Note, in meeting: Meeting) -> Bool {
        if selectedNoteID == note.id { return true }
        guard let currentSegmentID else { return false }
        return meeting.segment(for: note)?.id == currentSegmentID
    }

    private func movePlayer(to segment: TranscriptSegment, in meeting: Meeting) {
        guard recording.meetingID != meeting.id, store.hasAudio(meeting.id) else { return }
        player.load(MeetingStore.audioURL(for: meeting.id))
        // Already inside this line (e.g. playback brought us here): don't jump back to its start.
        let next = meeting.segments.first { $0.start > segment.start }?.start ?? .infinity
        if player.currentTime >= segment.start && player.currentTime < next { return }
        player.seek(to: segment.start)
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
