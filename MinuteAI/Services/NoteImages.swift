import AppKit
import UniformTypeIdentifiers

/// Images attached to notes. They are stored as PNG files in the meeting's folder,
/// and a note only keeps their file names.
@MainActor
enum NoteImages {
    private static let cache = NSCache<NSString, NSImage>()

    static func folder(for meetingID: UUID) -> URL {
        MeetingStore.folder(for: meetingID).appendingPathComponent("images", isDirectory: true)
    }

    static func url(_ name: String, meetingID: UUID) -> URL {
        folder(for: meetingID).appendingPathComponent(name)
    }

    static func image(_ name: String, meetingID: UUID) -> NSImage? {
        let url = url(name, meetingID: meetingID)
        if let cached = cache.object(forKey: url.path as NSString) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: url.path as NSString)
        return image
    }

    /// Stores the image and returns its file name.
    static func save(_ image: NSImage, meetingID: UUID) -> String? {
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return nil }
        let name = "\(UUID().uuidString).png"
        do {
            try FileManager.default.createDirectory(at: folder(for: meetingID), withIntermediateDirectories: true)
            try png.write(to: url(name, meetingID: meetingID), options: .atomic)
            return name
        } catch {
            NSLog("MinuteAI: failed to save note image: \(error)")
            return nil
        }
    }

    static func importFiles(_ urls: [URL], meetingID: UUID) -> [String] {
        urls.compactMap { NSImage(contentsOf: $0) }.compactMap { save($0, meetingID: meetingID) }
    }

    /// Image files copied in Finder, or image data copied from a screenshot, browser or other app.
    private static func pasteboardFiles() -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        return NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    static var pasteboardHasImage: Bool {
        !pasteboardFiles().isEmpty || NSPasteboard.general.canReadObject(forClasses: [NSImage.self])
    }

    /// True when pasting should attach an image rather than insert text: the clipboard holds
    /// image files, or image data with no text alongside it.
    static var pasteboardIsImageOnly: Bool {
        if !pasteboardFiles().isEmpty { return true }
        return NSPasteboard.general.canReadObject(forClasses: [NSImage.self])
            && NSPasteboard.general.string(forType: .string) == nil
    }

    static func importPasteboard(meetingID: UUID) -> [String] {
        let files = pasteboardFiles()
        if !files.isEmpty { return importFiles(files, meetingID: meetingID) }
        guard let image = NSImage(pasteboard: .general), let name = save(image, meetingID: meetingID) else { return [] }
        return [name]
    }

    static func chooseFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "メモに貼る画像を選択"
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func delete(_ names: [String], meetingID: UUID) {
        for name in names {
            let url = url(name, meetingID: meetingID)
            cache.removeObject(forKey: url.path as NSString)
            try? FileManager.default.removeItem(at: url)
        }
    }
}
