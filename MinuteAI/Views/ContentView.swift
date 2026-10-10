import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            if let meeting = app.store.meeting(app.selection) {
                MeetingView(meeting: meeting)
                    .id(meeting.id)
            } else {
                ContentUnavailableView {
                    Label("会議が選択されていません", systemImage: "waveform")
                } description: {
                    Text("新しい会議を作成して録音を始めましょう。")
                } actions: {
                    Button("新しい会議") { app.newMeeting() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .alert("エラー", isPresented: Binding(
            get: { app.recording.errorMessage != nil },
            set: { if !$0 { app.recording.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.recording.errorMessage ?? "")
        }
    }
}

struct SidebarView: View {
    @Environment(AppState.self) private var app
    @State private var deleteTarget: Meeting?

    private var results: [Meeting] {
        app.store.meetings.filter { $0.matches(app.searchText) }
    }

    var body: some View {
        @Bindable var app = app
        List(selection: $app.selection) {
            ForEach(results) { meeting in
                row(meeting)
                    .tag(meeting.id)
                    .contextMenu {
                        Button("削除…", role: .destructive) { deleteTarget = meeting }
                            .disabled(!app.canDelete(meeting.id))
                    }
            }
        }
        .searchable(text: $app.searchText, placement: .sidebar, prompt: "会議を検索")
        .safeAreaInset(edge: .bottom) {
            if let error = app.store.saveError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
            }
            if !app.store.unreadableFolders.isEmpty {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(app.store.unreadableFolders)
                } label: {
                    Label("読み込めない会議が\(app.store.unreadableFolders.count)件あります", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                }
                .buttonStyle(.link)
                .padding(8)
                .help("meeting.json が壊れている会議です。クリックすると Finder でフォルダを表示します")
            }
        }
        .overlay {
            if results.isEmpty {
                Text(app.searchText.isEmpty ? "会議はまだありません" : "一致する会議がありません")
                    .foregroundStyle(.secondary)
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    app.newMeeting()
                } label: {
                    Label("新しい会議", systemImage: "square.and.pencil")
                }
                .help("新しい会議 (⌘N)")
            }
            ToolbarItem {
                SettingsLink {
                    Label("設定", systemImage: "gearshape")
                }
                .help("設定(モデルのダウンロードと選択) (⌘,)")
            }
        }
        .confirmationDialog(
            "「\(deleteTarget?.title ?? "")」を削除しますか?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
        ) {
            Button("削除", role: .destructive) {
                if let deleteTarget { app.deleteMeeting(deleteTarget.id) }
                deleteTarget = nil
            }
        } message: {
            Text("文字起こし・メモ・要約・録音がすべて削除されます。この操作は取り消せません。")
        }
    }

    private func row(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if app.recording.meetingID == meeting.id {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                }
                Text(meeting.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(meeting.createdAt, format: .dateTime.year().month().day().hour().minute())
                if meeting.duration > 0 {
                    Text(formatTime(meeting.duration))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !app.searchText.isEmpty, let snippet = meeting.snippet(for: app.searchText), snippet != meeting.title {
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}
