import SwiftUI

struct MeetingView: View {
    @Environment(AppState.self) private var app
    let meeting: Meeting

    @State private var sidePanel = SidePanel.notes

    enum SidePanel: String, CaseIterable {
        case notes = "メモ"
        case summary = "要約"
    }

    private var recording: RecordingController { app.recording }
    private var isActive: Bool { recording.meetingID == meeting.id }
    private var hasAudio: Bool { !isActive && app.store.hasAudio(meeting.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                TranscriptView(meeting: meeting, canPlay: hasAudio)
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 0) {
                    Picker("", selection: $sidePanel) {
                        ForEach(SidePanel.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(8)
                    .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Group {
                        switch sidePanel {
                        case .notes: NotesView(meeting: meeting)
                        case .summary: SummaryView(meeting: meeting)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(minWidth: 300, idealWidth: 360, maxWidth: 560, maxHeight: .infinity)
            }
            if hasAudio {
                Divider()
                PlayerBar(meeting: meeting)
            } else if app.store.recovering.contains(meeting.id) {
                Divider()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("前回中断された録音を復旧しています…")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(8)
            }
        }
        .toolbar { toolbar }
        .onChange(of: app.noteTargetSegmentID) {
            if app.noteTargetSegmentID != nil { sidePanel = .notes }
        }
        .onAppear(perform: loadAudio)
        .onChange(of: hasAudio) { loadAudio() }
    }

    private func loadAudio() {
        if hasAudio {
            app.player.load(MeetingStore.audioURL(for: meeting.id))
        } else {
            app.player.stop()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                TextField("会議のタイトル", text: Binding(
                    get: { meeting.title },
                    set: { title in app.store.update(meeting.id) { $0.title = title } }))
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                usedModels
            }
            Spacer()
            if isActive {
                recordingStatus
            } else {
                Text(meeting.createdAt, format: .dateTime.year().month().day().weekday().hour().minute())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Which AI models produced this meeting's transcript and summary.
    private var usedModels: some View {
        HStack(spacing: 12) {
            if canChooseTranscriptionModel {
                HStack(spacing: 4) {
                    Label("文字起こし:", systemImage: "waveform")
                    Picker("文字起こしモデル", selection: Binding(
                        get: { recording.transcriptionVariant(for: meeting) },
                        set: { choice in app.store.update(meeting.id) { $0.transcriptionModelChoice = choice } })
                    ) {
                        ForEach(app.whisper.downloadedModels) { model in
                            Text(model.variant == app.settings.whisperVariant ? "\(model.name)(既定)" : model.name)
                                .tag(model.variant)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .help("この会議の文字起こしに使うモデル(録音を始めると変更できません)")
                }
            } else {
                Label("文字起こし: \(transcriptionModelText)", systemImage: "waveform")
                    .help(meeting.transcriptionModel ?? "")
            }
            if !meeting.summary.isEmpty {
                Label("要約: \(meeting.summaryModel.map(LLMModelManager.name) ?? "記録なし")", systemImage: "sparkles")
                    .help(meeting.summaryModel ?? "")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// The model can be picked until the meeting has been recorded.
    private var canChooseTranscriptionModel: Bool {
        !recording.isBusy && meeting.transcriptionModel == nil && meeting.segments.isEmpty
            && !app.store.hasAudio(meeting.id)
            && app.whisper.state(recording.transcriptionVariant(for: meeting)) == .downloaded
    }

    private var transcriptionModelText: String {
        if let model = meeting.transcriptionModel { return WhisperModelManager.name(model) }
        // Not recorded yet: this is the model the recording will use.
        if meeting.segments.isEmpty && !app.store.hasAudio(meeting.id) {
            return WhisperModelManager.name(recording.transcriptionVariant(for: meeting))
        }
        return "記録なし"
    }

    @ViewBuilder
    private var recordingStatus: some View {
        switch recording.phase {
        case .preparing(let message):
            ProgressView().controlSize(.small)
            Text(message).foregroundStyle(.secondary)
        case .finishing:
            ProgressView().controlSize(.small)
            Text("残りの音声を文字起こし中…").foregroundStyle(.secondary)
        case .recording:
            if app.settings.captureMicrophone {
                LevelMeter(symbol: "mic.fill", level: recording.micLevel)
                    .help("マイクの入力レベル")
            }
            if app.settings.captureSystemAudio {
                LevelMeter(symbol: "speaker.wave.2.fill", level: recording.systemLevel)
                    .help("システム音声(リモート会議の相手)の入力レベル")
            }
            Image(systemName: "record.circle.fill").foregroundStyle(.red)
            Text(formatTime(recording.elapsed))
                .monospacedDigit()
                .fontWeight(.medium)
        case .idle:
            EmptyView()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if recording.isRecording(meeting.id) {
                Button {
                    Task { await recording.stop() }
                } label: {
                    Label("録音を停止", systemImage: "stop.fill")
                }
                .labelStyle(.titleAndIcon)
                .tint(.red)
            } else if !app.store.hasAudio(meeting.id) && meeting.segments.isEmpty
                && !app.store.recovering.contains(meeting.id) {
                Button {
                    Task { await recording.start(meetingID: meeting.id) }
                } label: {
                    Label("録音を開始", systemImage: "record.circle")
                }
                .labelStyle(.titleAndIcon)
                .disabled(recording.isBusy)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Markdown (.md)…") {
                    Exporter.save(
                        text: Exporter.markdown(meeting, categories: app.settings.categories),
                        suggestedName: meeting.title, type: .init(filenameExtension: "md") ?? .plainText)
                }
                Button("テキスト (.txt)…") {
                    Exporter.save(
                        text: Exporter.plainText(meeting, categories: app.settings.categories),
                        suggestedName: meeting.title, type: .plainText)
                }
                Divider()
                Button("録音した音声 (.m4a)…") { Exporter.saveAudio(of: meeting) }
                    .disabled(!hasAudio)
                Button("保存フォルダを Finder で表示") {
                    NSWorkspace.shared.activateFileViewerSelecting([MeetingStore.folder(for: meeting.id)])
                }
            } label: {
                Label("書き出し", systemImage: "square.and.arrow.up")
            }
            .disabled(isActive)
        }
    }
}

struct LevelMeter: View {
    let symbol: String
    let level: Float

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.green)
                        .frame(width: proxy.size.width * CGFloat(min(1, (level * 6).squareRoot())))
                }
            }
            .frame(width: 44, height: 5)
        }
        .animation(.linear(duration: 0.1), value: level)
    }
}

struct PlayerBar: View {
    @Environment(AppState.self) private var app
    let meeting: Meeting

    var body: some View {
        let player = app.player
        HStack(spacing: 10) {
            Button {
                player.load(MeetingStore.audioURL(for: meeting.id))
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.space, modifiers: [.option])
            .help("再生 / 一時停止 (⌥Space)")
            Text(formatTime(player.currentTime)).monospacedDigit()
            Slider(
                value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                in: 0...max(player.duration, 1))
            Text(formatTime(player.duration)).monospacedDigit()
            if let error = player.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            Slider(
                value: Binding(get: { player.gain }, set: { player.gain = $0 }),
                in: AudioPlayer.gainRange)
                .frame(width: 90)
                .help("再生音量。100% が録音そのままの大きさです")
            Text("\(Int((pow(10, Double(player.gain) / 20) * 100).rounded()))%")
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
            Button {
                Exporter.saveAudio(of: meeting)
            } label: {
                Label("音声を保存", systemImage: "arrow.down.circle")
            }
            .help("録音した音声 (.m4a) をファイルに保存")
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
