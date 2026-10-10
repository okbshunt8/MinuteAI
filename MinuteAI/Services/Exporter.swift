import AppKit
import UniformTypeIdentifiers

/// Writes a meeting out as Markdown, plain text or the recorded audio file.
@MainActor
enum Exporter {
    static func markdown(_ meeting: Meeting, categories: [NoteCategory]) -> String {
        var out = "# \(meeting.title)\n\n"
        out += "- 日時: \(dateText(meeting.createdAt))\n"
        out += "- 録音時間: \(formatTime(meeting.duration))\n"
        if let model = meeting.transcriptionModel { out += "- 文字起こしモデル: \(WhisperModelManager.name(model))\n" }
        if let model = meeting.summaryModel, !meeting.summary.isEmpty {
            out += "- 要約モデル: \(LLMModelManager.name(model))\n"
        }
        out += "\n"
        if !meeting.summary.isEmpty {
            out += "# 要約\n\n\(meeting.summary)\n\n"
        }
        if !meeting.notes.isEmpty {
            out += "# メモ\n\n"
            for note in meeting.notes {
                let category = categories.first { $0.id == note.categoryID }?.name ?? "メモ"
                let time = note.time.map { " (\(formatTime($0)))" } ?? ""
                let check = note.categoryID == NoteCategory.taskID ? (note.done ? "[x] " : "[ ] ") : ""
                out += "- \(check)**\(category)**\(time) \(note.text.replacingOccurrences(of: "\n", with: " "))\n"
                for name in note.images ?? [] {
                    out += "  ![](\(NoteImages.url(name, meetingID: meeting.id).absoluteString))\n"
                }
            }
            out += "\n"
        }
        if !meeting.segments.isEmpty {
            out += "# 文字起こし\n\n"
            for segment in meeting.segments {
                if let chapter = segment.chapterTitle, !chapter.isEmpty { out += "\n## \(chapter)\n\n" }
                let text = segment.marker != nil ? "==\(segment.text)==" : segment.text
                out += "- `\(formatTime(segment.start))` \(text)\n"
            }
        }
        return out
    }

    static func plainText(_ meeting: Meeting, categories: [NoteCategory]) -> String {
        var out = "\(meeting.title)\n日時: \(dateText(meeting.createdAt))\n録音時間: \(formatTime(meeting.duration))\n"
        if let model = meeting.transcriptionModel { out += "文字起こしモデル: \(WhisperModelManager.name(model))\n" }
        if let model = meeting.summaryModel, !meeting.summary.isEmpty {
            out += "要約モデル: \(LLMModelManager.name(model))\n"
        }
        if !meeting.summary.isEmpty {
            out += "\n■ 要約\n\(meeting.summary)\n"
        }
        if !meeting.notes.isEmpty {
            out += "\n■ メモ\n"
            for note in meeting.notes {
                let category = categories.first { $0.id == note.categoryID }?.name ?? "メモ"
                let time = note.time.map { " \(formatTime($0))" } ?? ""
                let images = (note.images ?? []).isEmpty ? "" : " (画像\(note.images?.count ?? 0)枚)"
                out += "[\(category)\(time)] \(note.text)\(images)\n"
            }
        }
        if !meeting.segments.isEmpty {
            out += "\n■ 文字起こし\n"
            for segment in meeting.segments {
                if let chapter = segment.chapterTitle, !chapter.isEmpty { out += "\n◆ \(chapter)\n" }
                out += "[\(formatTime(segment.start))]\(segment.marker != nil ? " ★" : "") \(segment.text)\n"
            }
        }
        return out
    }

    static func save(text: String, suggestedName: String, type: UTType) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = safeFileName(suggestedName)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func saveAudio(of meeting: Meeting) {
        let source = MeetingStore.audioURL(for: meeting.id)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.nameFieldStringValue = safeFileName(meeting.title)
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: source, to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private static func safeFileName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy/MM/dd (E) HH:mm"
        return formatter.string(from: date)
    }
}
