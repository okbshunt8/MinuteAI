import Foundation
import SwiftUI

enum MarkerColor: String, Codable, CaseIterable, Identifiable {
    case yellow, green, pink, blue

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .yellow: return .yellow
        case .green: return .green
        case .pink: return .pink
        case .blue: return .blue
        }
    }

    var label: String {
        switch self {
        case .yellow: return "黄"
        case .green: return "緑"
        case .pink: return "ピンク"
        case .blue: return "青"
        }
    }
}

struct TranscriptSegment: Identifiable, Codable, Equatable {
    var id = UUID()
    /// Seconds from the start of the recording.
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var marker: MarkerColor?
    /// Heading of the chapter that starts at this line, if one does.
    var chapterTitle: String?
    /// True when the heading was written by the language model rather than by hand.
    var chapterIsAuto: Bool?
}

struct NoteCategory: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var colorName: String

    static let palette = ["gray", "red", "orange", "yellow", "green", "teal", "blue", "purple", "pink"]

    var color: Color {
        switch colorName {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "teal": return .teal
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        default: return .gray
        }
    }

    static let taskID = "task"
    static let memoID = "memo"

    static let defaults: [NoteCategory] = [
        NoteCategory(id: memoID, name: "メモ", colorName: "gray"),
        NoteCategory(id: "issue", name: "課題", colorName: "red"),
        NoteCategory(id: taskID, name: "タスク", colorName: "blue"),
        NoteCategory(id: "decision", name: "決定事項", colorName: "green"),
        NoteCategory(id: "question", name: "質問", colorName: "orange"),
    ]
}

struct Note: Identifiable, Codable, Equatable {
    var id = UUID()
    var createdAt = Date()
    /// Seconds from the start of the recording when the note was written, if it was written while recording.
    var time: TimeInterval?
    /// The transcript line this note was written about, if one was picked.
    var segmentID: UUID?
    var categoryID: String
    var text: String
    var done = false
    /// File names of the images attached to the note, inside the meeting's images folder.
    var images: [String]?
}

struct Meeting: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var createdAt = Date()
    var duration: TimeInterval = 0
    var segments: [TranscriptSegment] = []
    var notes: [Note] = []
    var summary = ""
    /// Whisper variant the transcript was made with. Nil for meetings recorded before this was tracked.
    var transcriptionModel: String?
    /// Whisper variant picked for this meeting before recording. Nil means the default from the settings.
    var transcriptionModelChoice: String?
    /// Hugging Face id of the model that wrote the current summary.
    var summaryModel: String?
    /// Model picked for this meeting's summary. Nil means the default from the settings.
    var summaryModelChoice: String?

    /// The transcript line a note belongs to: the one it was attached to,
    /// otherwise the one being spoken when the note was written.
    func segment(for note: Note) -> TranscriptSegment? {
        if let id = note.segmentID, let segment = segments.first(where: { $0.id == id }) { return segment }
        guard let time = note.time else { return nil }
        return segments.last { $0.start <= time } ?? segments.first
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return true }
        return snippet(for: q) != nil
    }

    /// First piece of text in the meeting that contains the query.
    func snippet(for query: String) -> String? {
        if title.localizedCaseInsensitiveContains(query) { return title }
        if let s = segments.first(where: { $0.text.localizedCaseInsensitiveContains(query) }) { return s.text }
        if let n = notes.first(where: { $0.text.localizedCaseInsensitiveContains(query) }) { return n.text }
        if let line = summary.split(separator: "\n").first(where: { $0.localizedCaseInsensitiveContains(query) }) {
            return String(line)
        }
        return nil
    }
}

func formatTime(_ t: TimeInterval) -> String {
    let s = Int(t.rounded(.down))
    if s >= 3600 {
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
    return String(format: "%02d:%02d", s / 60, s % 60)
}
