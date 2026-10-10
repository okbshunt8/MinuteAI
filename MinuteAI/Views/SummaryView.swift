import SwiftUI

struct SummaryView: View {
    @Environment(AppState.self) private var app
    let meeting: Meeting

    @State private var editing = false

    private var isSummarizing: Bool { app.summarizingID == meeting.id }
    private var modelID: String { app.summaryModelID(for: meeting) }
    private var modelReady: Bool { app.llm.state(modelID) == .downloaded }
    private var isRecordingHere: Bool { app.recording.meetingID == meeting.id }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if meeting.summary.isEmpty && !isSummarizing {
                ContentUnavailableView(
                    "要約はまだありません", systemImage: "sparkles",
                    description: Text("会議が終わったら「要約を生成」を押してください。マーカーを付けた発言とメモを重視して要約します。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if editing {
                TextEditor(text: Binding(
                    get: { meeting.summary },
                    set: { summary in app.store.update(meeting.id) { $0.summary = summary } }))
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    MarkdownText(text: meeting.summary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if isSummarizing {
                    ProgressView().controlSize(.small)
                    Text(app.summaryStatus)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("中止") { app.cancelSummary() }
                } else {
                    Button {
                        editing = false
                        app.summarize(meeting.id)
                    } label: {
                        Label(meeting.summary.isEmpty ? "要約を生成" : "再生成", systemImage: "sparkles")
                    }
                    .disabled(!modelReady || app.isModelBusy || isRecordingHere
                        || (meeting.segments.isEmpty && meeting.notes.isEmpty))
                    if modelReady {
                        Picker("要約に使うモデル", selection: Binding(
                            get: { modelID },
                            set: { choice in app.store.update(meeting.id) { $0.summaryModelChoice = choice } })
                        ) {
                            ForEach(app.llm.downloadedModels) { model in
                                Text(model.id == app.settings.llmModelID ? "\(model.name)(既定)" : model.name)
                                    .tag(model.id)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .help("この会議の要約に使うモデル")
                    }
                    Spacer()
                    if !meeting.summary.isEmpty {
                        Toggle("編集", isOn: $editing)
                            .toggleStyle(.button)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(meeting.summary, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .help("要約をコピー")
                    }
                }
            }
            if !modelReady {
                HStack(spacing: 4) {
                    Text("要約モデルが未ダウンロードです。")
                    SettingsLink { Text("設定を開く") }
                        .buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if isRecordingHere {
                Text("録音を停止すると要約を生成できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = app.summaryError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(10)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Renders the subset of Markdown the summary uses: headings, bullets and inline emphasis.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                line(raw)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func line(_ raw: String) -> some View {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let indent = CGFloat(raw.prefix { $0 == " " }.count) * 6
        if trimmed.isEmpty {
            Spacer().frame(height: 2)
        } else if trimmed.hasPrefix("#") {
            let level = trimmed.prefix { $0 == "#" }.count
            Text(inline(String(trimmed.drop { $0 == "#" || $0 == " " })))
                .font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 6)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(String(trimmed.dropFirst(2))))
            }
            .padding(.leading, indent)
        } else {
            Text(inline(trimmed))
                .padding(.leading, indent)
        }
    }

    private func inline(_ string: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: string, options: options)) ?? AttributedString(string)
    }
}
