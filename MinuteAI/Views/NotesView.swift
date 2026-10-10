import QuickLook
import SwiftUI

struct NotesView: View {
    @Environment(AppState.self) private var app
    let meeting: Meeting
    /// False while the summary is shown in front of the notes.
    var isVisible = true

    @State private var draft = ""
    @State private var categoryID = NoteCategory.memoID
    @State private var filter: String?
    /// Images waiting to be attached to the note being written.
    @State private var pendingImages: [String] = []
    @State private var pasteMonitor: Any?
    @FocusState private var inputFocused: Bool

    private var notes: [Note] {
        guard let filter else { return meeting.sortedNotes }
        return meeting.sortedNotes.filter { $0.categoryID == filter }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if notes.isEmpty {
                ContentUnavailableView(
                    "メモはまだありません", systemImage: "note.text",
                    description: Text("下の入力欄からカテゴリを選んでメモを追加できます。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(notes) { note in
                                NoteRow(
                                    note: note, meeting: meeting,
                                    quote: note.segmentID != nil ? meeting.segment(for: note)?.text : nil)
                                    .id(note.id)
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: meeting.notes.count) { old, new in
                        // Notes are in meeting order, so a new one can land anywhere: show it.
                        guard new > old, let added = meeting.notes.max(by: { $0.createdAt < $1.createdAt }) else { return }
                        proxy.scrollTo(added.id, anchor: .center)
                    }
                    .onChange(of: app.notesScrollRequest) {
                        // The current position moved in the transcript or the player: show its notes.
                        guard let note = notes.first(where: { app.isHighlighted($0, in: meeting) }) else { return }
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(note.id, anchor: .center) }
                    }
                }
            }
            Divider()
            input
        }
        .onAppear {
            if !app.settings.categories.contains(where: { $0.id == categoryID }) {
                categoryID = app.settings.categories.first?.id ?? NoteCategory.memoID
            }
            if app.noteTargetSegmentID != nil { inputFocused = true }
            if isVisible { installPasteMonitor() }
        }
        .onDisappear {
            removePasteMonitor()
            // Images of a note that was never added would otherwise stay on disk forever.
            NoteImages.delete(pendingImages, meetingID: meeting.id)
            pendingImages = []
        }
        .onChange(of: isVisible) {
            // The monitor only exists while the notes are in front, so ⌘V elsewhere is left alone.
            if isVisible {
                installPasteMonitor()
                // Coming to the front to write about a transcript line: the field was disabled until now.
                if app.noteTargetSegmentID != nil { inputFocused = true }
            } else {
                removePasteMonitor()
                inputFocused = false
            }
        }
        .onChange(of: app.noteTargetSegmentID) {
            if app.noteTargetSegmentID != nil { inputFocused = true }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let names = NoteImages.importFiles(urls, meetingID: meeting.id)
            pendingImages += names
            return !names.isEmpty
        }
    }

    /// ⌘V with an image on the clipboard attaches it to the note being written.
    /// Text fields only paste text, so the key is caught before it reaches them.
    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command, event.charactersIgnoringModifiers == "v",
                  event.window?.title == "MinuteAI", NoteImages.pasteboardIsImageOnly
            else { return event }
            pasteImage()
            return nil
        }
    }

    private func removePasteMonitor() {
        if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
        pasteMonitor = nil
    }

    private func pasteImage() {
        pendingImages += NoteImages.importPasteboard(meetingID: meeting.id)
        inputFocused = true
    }

    /// Transcript line the note being written will be attached to.
    private var target: TranscriptSegment? {
        guard let id = app.noteTargetSegmentID else { return nil }
        return meeting.segments.first { $0.id == id }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("すべて", color: .secondary, selected: filter == nil) { filter = nil }
                ForEach(app.settings.categories) { category in
                    let count = meeting.notes.filter { $0.categoryID == category.id }.count
                    chip("\(category.name) \(count)", color: category.color, selected: filter == category.id) {
                        filter = filter == category.id ? nil : category.id
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(app.settings.categories.enumerated()), id: \.element.id) { index, category in
                        chip(category.name, color: category.color, selected: categoryID == category.id) {
                            categoryID = category.id
                            inputFocused = true
                        }
                        .keyboardShortcut(index < 9 ? KeyEquivalent(Character("\(index + 1)")) : "0", modifiers: .command)
                        .help(index < 9 ? "⌘\(index + 1)" : "")
                    }
                }
            }
            if let target {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                    Text(formatTime(target.start)).monospacedDigit()
                    Text(target.text).lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        app.cancelNoteTarget()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help("発言の指定を解除")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.16)))
            }
            if !pendingImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(pendingImages, id: \.self) { name in
                            if let image = NoteImages.image(name, meetingID: meeting.id) {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .overlay(alignment: .topTrailing) {
                                        Button {
                                            pendingImages.removeAll { $0 == name }
                                            NoteImages.delete([name], meetingID: meeting.id)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.white, .black.opacity(0.6))
                                        }
                                        .buttonStyle(.plain)
                                        .padding(2)
                                        .help("この画像を外す")
                                    }
                            }
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                Menu {
                    Button("クリップボードの画像を貼り付け", action: pasteImage)
                        .disabled(!NoteImages.pasteboardHasImage)
                    Button("画像ファイルを選択…") {
                        pendingImages += NoteImages.importFiles(NoteImages.chooseFiles(), meetingID: meeting.id)
                    }
                } label: {
                    Image(systemName: "photo.badge.plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.bottom, 5)
                .help("画像を貼る(⌘V でクリップボードの画像を貼り付け)")
                TextField(
                    target == nil ? "メモを入力(Enterで追加、⌥Enterで改行)" : "この発言へのメモを入力",
                    text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .focused($inputFocused)
                    .onSubmit(add)
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
                Button(action: add) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingImages.isEmpty
                    ? Color.secondary : Color.accentColor)
                .help("メモを追加")
            }
        }
        .padding(10)
    }

    private func chip(_ title: String, color: Color, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(selected ? color.opacity(0.85) : color.opacity(0.15)))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingImages.isEmpty else { return }
        let time = target?.start ?? (app.recording.isRecording(meeting.id) ? app.recording.elapsed : nil)
        let note = Note(
            time: time, segmentID: target?.id, categoryID: categoryID, text: text,
            images: pendingImages.isEmpty ? nil : pendingImages)
        app.store.update(meeting.id) { $0.notes.append(note) }
        app.cancelNoteTarget()
        draft = ""
        pendingImages = []
        if let filter, filter != categoryID { self.filter = nil }
        inputFocused = true
    }
}

private struct NoteRow: View {
    @Environment(AppState.self) private var app
    let note: Note
    let meeting: Meeting
    /// Text of the transcript line the note was attached to.
    let quote: String?

    private var meetingID: UUID { meeting.id }
    private var isSelected: Bool { app.isHighlighted(note, in: meeting) }

    @State private var hovering = false
    @State private var editing = false
    @State private var confirmingDelete = false
    @State private var imageToDelete: String?
    @State private var previewURL: URL?
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let category = app.settings.category(note.categoryID)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if note.categoryID == NoteCategory.taskID {
                Button {
                    update { $0.done.toggle() }
                } label: {
                    Image(systemName: note.done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(note.done ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(note.done ? "未完了に戻す" : "完了にする")
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Menu {
                        ForEach(app.settings.categories) { option in
                            Button(option.name) { update { $0.categoryID = option.id } }
                        }
                    } label: {
                        Text(category.name)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(category.color.opacity(0.85)))
                    .help("カテゴリを変更")
                    if let time = note.time {
                        Text(formatTime(time))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if app.relinkingNoteID == note.id {
                        Text("発言を選択中…")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                    if hovering && !editing {
                        Button {
                            app.startRelinking(note)
                        } label: {
                            Image(systemName: "link")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("紐づける発言を変更(押したあと、文字起こしの行をクリック)")
                        Button(action: startEditing) {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("メモを編集")
                        Button {
                            confirmingDelete = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("メモを削除")
                    }
                }
                if let quote, quote != note.text {
                    Text("「\(quote)」")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if editing {
                    TextField("", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit(commit)
                        .onExitCommand { editing = false }
                } else if !note.text.isEmpty {
                    Text(note.text)
                        .strikethrough(note.done && note.categoryID == NoteCategory.taskID)
                        .foregroundStyle(note.done && note.categoryID == NoteCategory.taskID ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(note.images ?? [], id: \.self) { name in
                    if let image = NoteImages.image(name, meetingID: meetingID) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 140, alignment: .leading)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .onTapGesture { previewURL = NoteImages.url(name, meetingID: meetingID) }
                            .help("クリックで拡大")
                            .contextMenu {
                                Button("拡大表示") { previewURL = NoteImages.url(name, meetingID: meetingID) }
                                Button("画像をコピー") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.writeObjects([image])
                                }
                                Button("画像を削除…", role: .destructive) { imageToDelete = name }
                            }
                    }
                }
            }
        }
        .quickLookPreview($previewURL)
        .confirmationDialog(
            "この画像を削除しますか?",
            isPresented: Binding(get: { imageToDelete != nil }, set: { if !$0 { imageToDelete = nil } })
        ) {
            Button("削除", role: .destructive) {
                if let name = imageToDelete {
                    update { $0.images = $0.images?.filter { $0 != name } }
                    NoteImages.delete([name], meetingID: meetingID)
                }
                imageToDelete = nil
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(category.color.opacity(isSelected ? 0.2 : 0.08)))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        // A single tap only: waiting to rule out a double click made selecting feel sluggish.
        .onTapGesture { app.select(note, in: meeting) }
        .help(meeting.segment(for: note) != nil ? "クリックで文字起こしと再生位置を該当箇所へ移動" : "")
        .contextMenu {
            Button("編集", action: startEditing)
            Button("紐づける発言を変更…") { app.startRelinking(note) }
            Button("発言との紐づけを解除") { app.unlink(note, in: meeting) }
                .disabled(note.segmentID == nil && note.time == nil)
            Button("クリップボードの画像を貼り付け") {
                attach(NoteImages.importPasteboard(meetingID: meetingID))
            }
            .disabled(!NoteImages.pasteboardHasImage)
            Button("画像ファイルを追加…") {
                attach(NoteImages.importFiles(NoteImages.chooseFiles(), meetingID: meetingID))
            }
            Button("削除…", role: .destructive) { confirmingDelete = true }
        }
        .confirmationDialog("このメモを削除しますか?", isPresented: $confirmingDelete) {
            Button("削除", role: .destructive) {
                app.store.update(meetingID) { $0.notes.removeAll { $0.id == note.id } }
                NoteImages.delete(note.images ?? [], meetingID: meetingID)
            }
        } message: {
            Text(note.text.isEmpty ? "画像のメモ" : note.text)
        }
        .onHover { hovering = $0 }
    }

    private func attach(_ names: [String]) {
        guard !names.isEmpty else { return }
        update { $0.images = ($0.images ?? []) + names }
    }

    private func startEditing() {
        draft = note.text
        editing = true
        focused = true
    }

    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { update { $0.text = text } }
        editing = false
    }

    private func update(_ change: (inout Note) -> Void) {
        app.store.update(meetingID) { meeting in
            guard let index = meeting.notes.firstIndex(where: { $0.id == note.id }) else { return }
            change(&meeting.notes[index])
        }
    }
}
