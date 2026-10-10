import Foundation
import Observation

/// Persists meetings as one folder per meeting under Application Support. Nothing leaves the machine.
@MainActor
@Observable
final class MeetingStore {
    private(set) var meetings: [Meeting] = []
    /// Meetings whose recording was cut off and is being rebuilt from its raw copy.
    private(set) var recovering: Set<UUID> = []
    /// Meeting folders whose meeting.json exists but could not be read. They are left untouched.
    private(set) var unreadableFolders: [URL] = []
    /// Set while changes could not be written to disk. They stay queued and are retried.
    private(set) var saveError: String?

    @ObservationIgnored private var pendingSaves: Set<UUID> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    static let rootURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MinuteAI", isDirectory: true)
    }()

    static var meetingsURL: URL { rootURL.appendingPathComponent("Meetings", isDirectory: true) }
    static var modelsURL: URL { rootURL.appendingPathComponent("Models", isDirectory: true) }

    static func folder(for id: UUID) -> URL {
        meetingsURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func audioURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("audio.m4a")
    }

    private static func jsonURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("meeting.json")
    }

    init() {
        load()
    }

    private func load() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.meetingsURL, withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let folders = (try? fm.contentsOfDirectory(at: Self.meetingsURL, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Meeting] = []
        for folder in folders {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("meeting.json")) else { continue }
            do {
                loaded.append(try decoder.decode(Meeting.self, from: data))
            } catch {
                NSLog("MinuteAI: could not read \(folder.lastPathComponent)/meeting.json: \(error)")
                unreadableFolders.append(folder)
            }
        }
        meetings = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    func meeting(_ id: UUID?) -> Meeting? {
        guard let id else { return nil }
        return meetings.first { $0.id == id }
    }

    @discardableResult
    func create() -> Meeting {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d HH:mm"
        let meeting = Meeting(title: "会議 \(formatter.string(from: Date()))")
        meetings.insert(meeting, at: 0)
        scheduleSave(meeting.id)
        return meeting
    }

    func update(_ id: UUID, _ change: (inout Meeting) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        change(&meetings[index])
        scheduleSave(id)
    }

    func delete(_ id: UUID) {
        pendingSaves.remove(id)
        meetings.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.folder(for: id))
    }

    func hasAudio(_ id: UUID) -> Bool {
        !recovering.contains(id) && FileManager.default.fileExists(atPath: Self.audioURL(for: id).path)
    }

    /// Repairs recordings that never got a clean stop. Call once at launch, before anything records.
    func recoverInterruptedRecordings() {
        for id in meetings.map(\.id) { recoverRecording(id) }
    }

    /// Rebuilds one meeting's audio from its raw copy, if it has one and is not already being rebuilt.
    func recoverRecording(_ id: UUID) {
        let audioURL = Self.audioURL(for: id)
        guard !recovering.contains(id),
              FileManager.default.fileExists(atPath: AudioRecorder.safetyCopyURL(for: audioURL).path)
        else { return }
        recovering.insert(id)
        Task {
            let duration = try? await Task.detached(priority: .utility) {
                try AudioRecorder.recover(audioURL: audioURL)
            }.value
            if let duration, duration > 0 {
                update(id) { $0.duration = max($0.duration, duration) }
            } else {
                NSLog("MinuteAI: could not recover the recording of meeting \(id)")
            }
            recovering.remove(id)
        }
    }

    private func scheduleSave(_ id: UUID) {
        pendingSaves.insert(id)
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.flush()
        }
    }

    /// Writes every meeting with unsaved changes to disk.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var failed: Set<UUID> = []
        var failure: Error?
        for id in pendingSaves {
            guard let meeting = meetings.first(where: { $0.id == id }) else { continue }
            do {
                try FileManager.default.createDirectory(at: Self.folder(for: id), withIntermediateDirectories: true)
                try encoder.encode(meeting).write(to: Self.jsonURL(for: id), options: .atomic)
            } catch {
                NSLog("MinuteAI: failed to save meeting \(id): \(error)")
                failed.insert(id)
                failure = error
            }
        }
        pendingSaves = failed
        if let failure {
            saveError = "会議の内容を保存できませんでした。ディスクの空き容量を確認してください。(\(failure.localizedDescription))"
            // Keep trying: the transcript and notes exist only in memory until this succeeds.
            saveTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.flush()
            }
        } else {
            saveError = nil
        }
    }
}
