import AVFoundation
import Observation

/// Drives one recording: audio capture, live transcription and writing the results into the meeting.
@MainActor
@Observable
final class RecordingController {
    enum Phase: Equatable {
        case idle
        case preparing(String)
        case recording
        case finishing
    }

    private(set) var phase: Phase = .idle
    private(set) var meetingID: UUID?
    private(set) var elapsed: TimeInterval = 0
    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0
    private(set) var provisionalText = ""
    var errorMessage: String?
    /// Things that went wrong during the recording without stopping it. Kept after the recording
    /// ends so they are not missed, until dismissed or the next recording starts.
    private(set) var warnings: [String] = []
    private(set) var warningsMeetingID: UUID?

    var isBusy: Bool { phase != .idle }

    func isRecording(_ id: UUID) -> Bool { meetingID == id && phase == .recording }

    @ObservationIgnored private let store: MeetingStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let whisper: WhisperModelManager
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private var transcriber: StreamingTranscriber?
    @ObservationIgnored private var clock: Timer?
    /// Keeps the Mac from idle-sleeping and the app from being throttled while recording.
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var startCancelled = false

    init(store: MeetingStore, settings: AppSettings, whisper: WhisperModelManager) {
        self.store = store
        self.settings = settings
        self.whisper = whisper
    }

    /// The model that will transcribe this meeting: the meeting's own choice if it is still
    /// downloaded, otherwise the default.
    func transcriptionVariant(for meeting: Meeting?) -> String {
        if let choice = meeting?.transcriptionModelChoice, whisper.state(choice) == .downloaded { return choice }
        return settings.whisperVariant
    }

    func start(meetingID id: UUID) async {
        guard phase == .idle else { return }
        guard settings.captureMicrophone || settings.captureSystemAudio else {
            errorMessage = "録音する音声(マイク / システム音声)を少なくとも1つ有効にしてください。"
            return
        }
        // Leave .idle before the first suspension point, or a second click could start a second recording.
        phase = .preparing("準備中…")
        startCancelled = false
        meetingID = id
        elapsed = 0
        provisionalText = ""
        warnings = []
        warningsMeetingID = id
        let variant = transcriptionVariant(for: store.meeting(id))
        do {
            guard whisper.state(variant) == .downloaded else {
                throw TranscriptionError.modelNotDownloaded
            }
            if settings.captureMicrophone {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw RecordingError.microphoneDenied
                }
            }
            if startCancelled { throw CancellationError() }
            phase = .preparing("文字起こしモデルを読み込み中…(初回は数分かかることがあります)")
            let kit = try await whisper.load(variant)
            // The app may have been asked to quit while the model was loading: don't start recording then.
            if startCancelled { throw CancellationError() }

            let transcriber = StreamingTranscriber(kit: kit, language: settings.language) { [weak self] event in
                self?.handle(event, meetingID: id)
            }
            recorder.onTranscriptionSamples = { transcriber.append($0) }
            recorder.onLevels = { [weak self] mic, system in
                Task { @MainActor in
                    self?.micLevel = mic
                    self?.systemLevel = system
                }
            }
            recorder.onProblem = { [weak self] message in
                Task { @MainActor in self?.warn(message) }
            }
            try FileManager.default.createDirectory(at: MeetingStore.folder(for: id), withIntermediateDirectories: true)
            try recorder.start(
                to: MeetingStore.audioURL(for: id),
                microphone: settings.captureMicrophone, systemAudio: settings.captureSystemAudio)
            transcriber.start()
            self.transcriber = transcriber
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "会議を録音・文字起こし中")
            store.update(id) { $0.transcriptionModel = variant }
            phase = .recording
            clock = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.phase == .recording else { return }
                    self.elapsed = self.recorder.duration
                }
            }
        } catch {
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
            phase = .idle
            meetingID = nil
        }
    }

    /// Abandons a recording that is still being prepared.
    func cancelStart() {
        startCancelled = true
    }

    func stop() async {
        guard phase == .recording, let id = meetingID else { return }
        phase = .finishing
        let duration = stopCapture(id)
        await transcriber?.finish()
        transcriber = nil
        store.update(id) { $0.duration = duration }
        store.flush()
        provisionalText = ""
        phase = .idle
        meetingID = nil
    }

    /// Returns once no recording is being started, made or finished.
    func waitUntilIdle() async {
        while phase != .idle {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Finalizes the audio file right away, without waiting for the remaining transcription.
    /// Last resort for when the app is going away in the middle of a recording.
    func stopImmediately() {
        guard phase == .recording, let id = meetingID else { return }
        stopCapture(id)
        store.flush()
        phase = .idle
        meetingID = nil
    }

    func dismissWarnings() {
        warnings = []
    }

    private func warn(_ message: String) {
        if !warnings.contains(message) { warnings.append(message) }
    }

    @discardableResult
    private func stopCapture(_ id: UUID) -> TimeInterval {
        clock?.invalidate()
        clock = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        let duration = recorder.stop()
        if recorder.needsRecovery { store.recoverRecording(id) }
        elapsed = duration
        micLevel = 0
        systemLevel = 0
        store.update(id) { $0.duration = duration }
        return duration
    }

    private func handle(_ event: StreamingTranscriber.Event, meetingID id: UUID) {
        switch event {
        case .provisional(let text):
            provisionalText = text
        case .final(let segment):
            store.update(id) { $0.segments.append(segment) }
        case .failed(let start, let end):
            // Keep the gap visible so it can be listened to and typed in by hand.
            let segment = TranscriptSegment(start: start, end: end, text: "(この区間は文字起こしに失敗しました)")
            store.update(id) { $0.segments.append(segment) }
            warn("文字起こしに失敗した区間があります。録音は続いているので、あとで再生して確認してください。")
        }
    }

    enum RecordingError: LocalizedError {
        case microphoneDenied

        var errorDescription: String? {
            "マイクへのアクセスが許可されていません。システム設定 > プライバシーとセキュリティ > マイク で MinuteAI を許可してください。"
        }
    }
}
