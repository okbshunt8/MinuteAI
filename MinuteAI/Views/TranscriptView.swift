import SwiftUI

struct TranscriptView: View {
    @Environment(AppState.self) private var app
    let meeting: Meeting
    let canPlay: Bool

    @State private var markedOnly = false
    @State private var autoScroll = true
    /// Transcript line whose text is being corrected.
    @FocusState private var editingID: UUID?
    /// Chapter the transcript should scroll to.
    @State private var jumpTarget: UUID?

    private var isActive: Bool { app.recording.meetingID == meeting.id }

    /// Transcript line at the playback position, while playing or paused partway through.
    private var playingID: UUID? {
        let player = app.player
        guard canPlay, player.isPlaying || player.currentTime > 0 else { return nil }
        return meeting.segments.last { $0.start <= player.currentTime }?.id
    }
    private var chapters: [TranscriptSegment] {
        meeting.segments.filter { !($0.chapterTitle ?? "").isEmpty }
    }

    private var canGenerateChapters: Bool {
        !isActive && !app.isModelBusy && !meeting.segments.isEmpty
            && app.llm.state(app.summaryModelID(for: meeting)) == .downloaded
    }

    private var segments: [TranscriptSegment] {
        markedOnly ? meeting.segments.filter { $0.marker != nil } : meeting.segments
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("文字起こし").font(.headline)
                if !chapters.isEmpty {
                    Menu {
                        ForEach(chapters) { segment in
                            Button("\(formatTime(segment.start))  \(segment.chapterTitle ?? "")") {
                                jumpTarget = segment.id
                            }
                        }
                    } label: {
                        Label("章 \(chapters.count)", systemImage: "list.bullet")
                    }
                    .fixedSize()
                    .help("章へ移動")
                }
                Spacer()
                if app.chapteringID == meeting.id {
                    ProgressView().controlSize(.small)
                    Text(app.chapterStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("中止") { app.cancelChapters() }
                } else if !isActive && !meeting.segments.isEmpty {
                    Button {
                        app.generateChapters(meeting.id)
                    } label: {
                        Label("章立てを生成", systemImage: "sparkles")
                    }
                    .disabled(!canGenerateChapters)
                    .help("AI が話題の区切りに見出しを付けます。手で付けた見出しは変更されません")
                }
                Toggle("マーカーのみ", isOn: $markedOnly)
                    .toggleStyle(.checkbox)
                if isActive {
                    Toggle("自動スクロール", isOn: $autoScroll)
                        .toggleStyle(.checkbox)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if let error = app.chapterError, app.chapteringID == nil {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            if app.relinkingNoteID != nil {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                    Text("メモを紐づける発言をクリックしてください")
                    Spacer()
                    Button("キャンセル") { app.cancelRelinking() }
                        .keyboardShortcut(.cancelAction)
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.18))
            }
            Divider()
            if meeting.segments.isEmpty && !isActive {
                ContentUnavailableView(
                    "まだ文字起こしがありません", systemImage: "text.quote",
                    description: Text("「録音を開始」を押すと、マイクとMacで再生中の音声をリアルタイムで文字起こしします。"))
            } else {
                list
            }
        }
        .background(.background)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(segments) { segment in
                        SegmentRow(
                            segment: segment, meetingID: meeting.id, canPlay: canPlay, editingID: $editingID)
                    }
                    if isActive {
                        provisional
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: app.transcriptScrollRequest) { scrollToFocused(proxy) }
            .onChange(of: jumpTarget) {
                guard let target = jumpTarget else { return }
                jumpTarget = nil
                autoScroll = false
                if markedOnly { markedOnly = false }
                Task { @MainActor in
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(target, anchor: .top) }
                }
            }
            .onChange(of: playingID) {
                // The playback position leads: transcript and notes follow it.
                app.playbackMoved(to: playingID)
            }
            .onChange(of: editingID) {
                // Selecting a line makes it the current position for the notes and the player too.
                guard let segment = meeting.segments.first(where: { $0.id == editingID }) else { return }
                app.select(segment, in: meeting)
            }
            .onChange(of: meeting.segments.count) { scrollToBottom(proxy) }
            .onChange(of: app.recording.provisionalText) { scrollToBottom(proxy) }
        }
    }

    private var provisional: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, isActive: app.recording.phase == .recording)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            Text(app.recording.provisionalText.isEmpty ? "聞き取り中…" : app.recording.provisionalText)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private func scrollToFocused(_ proxy: ScrollViewProxy) {
        guard let id = app.currentSegmentID, let segment = meeting.segments.first(where: { $0.id == id }) else { return }
        // Otherwise the next transcribed line would pull the view back to the bottom.
        autoScroll = false
        if markedOnly && segment.marker == nil {
            // The line is hidden by the filter. Lift it only when a note was picked on purpose,
            // not every time playback passes an unmarked line.
            guard app.selectionSource == .note else { return }
            markedOnly = false
            Task { @MainActor in proxy.scrollTo(id, anchor: .center) }
        } else {
            withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        // Don't move the line out from under someone who is correcting it.
        guard isActive, autoScroll, !markedOnly, editingID == nil else { return }
        proxy.scrollTo("bottom", anchor: .bottom)
    }
}

private struct SegmentRow: View {
    @Environment(AppState.self) private var app
    let segment: TranscriptSegment
    let meetingID: UUID
    let canPlay: Bool
    var editingID: FocusState<UUID?>.Binding

    @State private var hovering = false
    @State private var draft = ""

    private var isEditing: Bool { editingID.wrappedValue == segment.id }

    /// This line is the current position shared with the notes and the player.
    private var isCurrent: Bool { app.currentSegmentID == segment.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title = segment.chapterTitle {
                ChapterHeader(
                    title: title, isAuto: segment.chapterIsAuto == true,
                    rename: { title in
                        update {
                            $0.chapterTitle = title
                            $0.chapterIsAuto = nil
                        }
                    },
                    remove: removeChapter)
            }
            row
        }
    }

    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                app.player.load(MeetingStore.audioURL(for: meetingID))
                app.player.seek(to: segment.start, play: true)
            } label: {
                Text(formatTime(segment.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                    .frame(width: 52, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .disabled(!canPlay)
            .help(canPlay ? "ここから再生" : "")

            // Always editable: click into the text and type to correct a misheard word.
            TextField("", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .focused(editingID, equals: segment.id)
                .onSubmit { editingID.wrappedValue = nil }
                .onExitCommand { editingID.wrappedValue = nil }
                .onAppear { draft = segment.text }
                .onChange(of: draft) { save() }
                .onChange(of: segment.text) {
                    if draft != segment.text { draft = segment.text }
                }
                .onChange(of: isEditing) {
                    // An emptied line keeps its previous text; deleting a line is a separate action.
                    if !isEditing && draft != segment.text { draft = segment.text }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Clicking a line that already has the cursor changes no focus, so select it here too.
                .simultaneousGesture(TapGesture().onEnded(selectLine))

            if hovering {
                markerButtons
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(segment.marker.map { $0.color.opacity(0.28) } ?? (hovering ? Color.primary.opacity(0.04) : .clear)))
        // A frame only, so it never hides the marker colour underneath.
        .overlay {
            if isCurrent {
                RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            editingID.wrappedValue = segment.id
            selectLine()
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("この発言にメモを書く") { app.startNote(on: segment) }
            if segment.chapterTitle == nil {
                Button("ここから新しい章(見出しを追加)", action: addChapter)
            } else {
                Button("見出しを削除", action: removeChapter)
            }
            Menu("マーカー") {
                ForEach(MarkerColor.allCases) { color in
                    Button(color.label) { setMarker(color) }
                }
                Divider()
                Button("マーカーを外す") { setMarker(nil) }
                    .disabled(segment.marker == nil)
            }
            Menu("発言をそのままメモに追加") {
                ForEach(app.settings.categories) { category in
                    Button(category.name) {
                        let note = Note(
                            time: segment.start, segmentID: segment.id, categoryID: category.id, text: segment.text)
                        app.store.update(meetingID) { $0.notes.append(note) }
                    }
                }
            }
            Button("コピー") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(segment.text, forType: .string)
            }
            Divider()
            Button("この行を削除", role: .destructive) {
                app.store.update(meetingID) { $0.segments.removeAll { $0.id == segment.id } }
            }
        }
    }

    private var markerButtons: some View {
        HStack(spacing: 4) {
            Button {
                app.startNote(on: segment)
            } label: {
                Image(systemName: "note.text.badge.plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("この発言にメモを書く")
            if segment.chapterTitle == nil {
                Button(action: addChapter) {
                    Image(systemName: "text.badge.plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("ここから新しい章(見出しを追加)")
            }
            Spacer().frame(width: 2)
            ForEach(MarkerColor.allCases) { color in
                Button {
                    setMarker(segment.marker == color ? nil : color)
                } label: {
                    Circle()
                        .fill(color.color)
                        .frame(width: 12, height: 12)
                        .overlay {
                            if segment.marker == color {
                                Circle().strokeBorder(Color.primary.opacity(0.7), lineWidth: 1.5)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(segment.marker == color ? "マーカーを外す" : "\(color.label)のマーカーを付ける")
            }
        }
    }

    private func selectLine() {
        guard let meeting = app.store.meeting(meetingID) else { return }
        app.select(segment, in: meeting)
    }

    private func setMarker(_ marker: MarkerColor?) {
        update { $0.marker = marker }
    }

    /// Starts a chapter at this line with an empty heading, ready to be typed.
    private func addChapter() {
        update {
            $0.chapterTitle = ""
            $0.chapterIsAuto = nil
        }
    }

    private func removeChapter() {
        update {
            $0.chapterTitle = nil
            $0.chapterIsAuto = nil
        }
    }

    private func update(_ change: (inout TranscriptSegment) -> Void) {
        app.store.update(meetingID) { meeting in
            guard let index = meeting.segments.firstIndex(where: { $0.id == segment.id }) else { return }
            change(&meeting.segments[index])
        }
    }

    /// Stores each change right away so the summary and exports always see the corrected text.
    private func save() {
        guard draft != segment.text, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        app.store.update(meetingID) { meeting in
            guard let index = meeting.segments.firstIndex(where: { $0.id == segment.id }) else { return }
            meeting.segments[index].text = draft
        }
    }
}

/// Heading shown above the line where a chapter starts. Always editable, like the transcript itself.
private struct ChapterHeader: View {
    let title: String
    let isAuto: Bool
    let rename: (String) -> Void
    let remove: () -> Void

    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: isAuto ? "sparkles" : "bookmark.fill")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .help(isAuto ? "AI が付けた見出し" : "手で付けた見出し")
            TextField("見出しを入力", text: $draft)
                .textFieldStyle(.plain)
                .font(.headline)
                .focused($focused)
                .onSubmit { focused = false }
                .onExitCommand { focused = false }
            if hovering {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("見出しを削除")
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 12)
        .padding(.bottom, 3)
        .overlay(alignment: .bottom) { Divider() }
        .onHover { hovering = $0 }
        .onAppear {
            draft = title
            // A heading that was just added starts empty: put the cursor in it.
            if title.isEmpty { DispatchQueue.main.async { focused = true } }
        }
        .onChange(of: draft) {
            if draft != title { rename(draft) }
        }
        .onChange(of: title) {
            if draft != title { draft = title }
        }
        .onChange(of: focused) {
            // Leaving a heading empty removes it again.
            if !focused && draft.trimmingCharacters(in: .whitespaces).isEmpty { remove() }
        }
    }
}
