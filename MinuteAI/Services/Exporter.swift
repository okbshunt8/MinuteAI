import AppKit
import UniformTypeIdentifiers

/// Writes a meeting out as Markdown, plain text or the recorded audio file.
@MainActor
enum Exporter {
    /// `imageFolder` is the folder next to the Markdown file that holds the notes' images.
    static func markdown(_ meeting: Meeting, categories: [NoteCategory], imageFolder: String? = nil) -> String {
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
            for note in meeting.sortedNotes {
                let category = NoteCategory.name(for: note.categoryID, in: categories)
                let time = note.time.map { " (\(formatTime($0)))" } ?? ""
                let check = note.categoryID == NoteCategory.taskID ? (note.done ? "[x] " : "[ ] ") : ""
                out += "- \(check)**\(category)**\(time) \(note.text.replacingOccurrences(of: "\n", with: " "))\n"
                if let imageFolder {
                    var allowed = CharacterSet.urlPathAllowed
                    allowed.remove(charactersIn: "()")
                    let folder = imageFolder.addingPercentEncoding(withAllowedCharacters: allowed) ?? imageFolder
                    for name in note.images ?? [] {
                        out += "  ![](\(folder)/\((name as NSString).lastPathComponent))\n"
                    }
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
            for note in meeting.sortedNotes {
                let category = NoteCategory.name(for: note.categoryID, in: categories)
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

    /// Saves the meeting as Markdown. Images attached to notes are copied into a folder next to
    /// the file and linked relatively, so the two can be moved or shared together.
    static func saveMarkdown(_ meeting: Meeting, categories: [NoteCategory]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = safeFileName(meeting.title)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let images = meeting.notes.flatMap { $0.images ?? [] }
        let imageFolder = images.isEmpty ? nil : url.deletingPathExtension().lastPathComponent + "-images"
        do {
            if let imageFolder {
                let folder = url.deletingLastPathComponent().appendingPathComponent(imageFolder, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for name in images {
                    let source = NoteImages.url(name, meetingID: meeting.id)
                    let target = folder.appendingPathComponent(source.lastPathComponent)
                    // A missing image must not stop the rest of the export.
                    if FileManager.default.fileExists(atPath: source.path),
                       !FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.copyItem(at: source, to: target)
                    }
                }
            }
            try markdown(meeting, categories: categories, imageFolder: imageFolder)
                .write(to: url, atomically: true, encoding: .utf8)
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
        // Picking the recording itself as the destination must not destroy it.
        guard url.standardizedFileURL != source.standardizedFileURL else { return }
        // Copy first and swap in afterwards, so a failed copy leaves any existing file intact.
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).m4a")
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
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
