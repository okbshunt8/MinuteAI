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
        meetingID = id
        elapsed = 0
        provisionalText = ""
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
            phase = .preparing("文字起こしモデルを読み込み中…(初回は数分かかることがあります)")
            let kit = try await whisper.load(variant)

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
            errorMessage = error.localizedDescription
            phase = .idle
            meetingID = nil
        }
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

    /// Finalizes the audio file right away, without waiting for the remaining transcription.
    /// Used when the app is quitting in the middle of a recording.
    func stopImmediately() {
        guard phase == .recording, let id = meetingID else { return }
        stopCapture(id)
        store.flush()
        phase = .idle
        meetingID = nil
    }

    @discardableResult
    private func stopCapture(_ id: UUID) -> TimeInterval {
        clock?.invalidate()
        clock = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        let duration = recorder.stop()
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
        }
    }

    enum RecordingError: LocalizedError {
        case microphoneDenied

        var errorDescription: String? {
            "マイクへのアクセスが許可されていません。システム設定 > プライバシーとセキュリティ > マイク で MinuteAI を許可してください。"
        }
    }
}
