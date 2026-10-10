import CryptoKit
import Foundation

/// Minimal Hugging Face downloader: fetches the weight/config/tokenizer files of a model repository
/// into a folder we control, so models can be listed and deleted from the app.
enum HFDownloader {
    private struct Entry: Decodable {
        let type: String
        let path: String
        let size: Int64?
        let lfs: LFS?

        struct LFS: Decodable {
            /// SHA-256 of the file.
            let oid: String
        }
    }

    private static let extensions: Set<String> = ["safetensors", "json", "jinja"]
    private static let completeMarker = ".complete"

    static func isComplete(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(completeMarker).path)
    }

    static func download(
        repo: String, to folder: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let files = try await files(repo: repo)
        guard files.contains(where: { $0.path.hasSuffix(".safetensors") }) else {
            throw DownloadError.noWeights(repo)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // Left behind if the app quit while a file was being verified.
        for leftover in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where leftover.pathExtension == "partial" {
            try? fm.removeItem(at: leftover)
        }
        let total = max(files.reduce(Int64(0)) { $0 + ($1.size ?? 0) }, 1)
        var finished: Int64 = 0

        for file in files {
            try Task.checkCancellation()
            let target = folder.appendingPathComponent(file.path)
            let size = file.size ?? 0
            let existing = (try? fm.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? -1
            if existing != size {
                guard let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file.path)") else {
                    throw URLError(.badURL)
                }
                let base = finished
                // Only a verified file gets its final name, so a half-checked one is never mistaken for complete.
                let partial = target.appendingPathExtension("partial")
                try await downloadFile(url, to: partial) { received in
                    progress(Double(base + received) / Double(total))
                }
                // Large files carry a checksum: catch truncated or corrupted downloads.
                if let expected = file.lfs?.oid, try sha256(of: partial) != expected.lowercased() {
                    try? fm.removeItem(at: partial)
                    throw DownloadError.corrupted(file.path)
                }
                try? fm.removeItem(at: target)
                try fm.moveItem(at: partial, to: target)
            }
            finished += size
            progress(Double(finished) / Double(total))
        }
        fm.createFile(atPath: folder.appendingPathComponent(completeMarker).path, contents: nil)
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The files of a repository that make up the model.
    private static func files(repo: String) async throws -> [Entry] {
        guard let listURL = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main?recursive=1") else {
            throw URLError(.badURL)
        }
        let (data, response) = try await URLSession.shared.data(from: listURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw DownloadError.repositoryNotFound(repo)
        }
        return try JSONDecoder().decode([Entry].self, from: data).filter {
            $0.type == "file" && !$0.path.contains("/")
                && extensions.contains(($0.path as NSString).pathExtension)
        }
    }

    /// Download size in bytes of each repository; repositories that cannot be read are left out.
    static func sizes(repos: [String]) async -> [String: Int64] {
        await withTaskGroup(of: (String, Int64?).self) { group in
            for repo in repos {
                group.addTask {
                    let files = try? await files(repo: repo)
                    return (repo, files.map { $0.reduce(Int64(0)) { $0 + ($1.size ?? 0) } })
                }
            }
            var result: [String: Int64] = [:]
            for await (repo, size) in group {
                if let size, size > 0 { result[repo] = size }
            }
            return result
        }
    }

    /// The architecture name from the repository's config.json.
    static func modelType(repo: String) async throws -> String? {
        struct Config: Decodable {
            let model_type: String?
        }
        guard let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/config.json") else {
            throw URLError(.badURL)
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw DownloadError.repositoryNotFound(repo)
        }
        return try JSONDecoder().decode(Config.self, from: data).model_type
    }

    struct ListedModel: Decodable {
        struct Config: Decodable {
            let model_type: String?
        }

        let id: String
        let downloads: Int?
        let config: Config?

        var modelType: String? { config?.model_type }
    }

    /// Text-generation models published in MLX format by the mlx-community organization, most downloaded first.
    static func listModels(query: String) async throws -> [ListedModel] {
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        components.queryItems = [
            URLQueryItem(name: "author", value: "mlx-community"),
            URLQueryItem(name: "pipeline_tag", value: "text-generation"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: "60"),
            URLQueryItem(name: "expand[]", value: "config"),
            URLQueryItem(name: "expand[]", value: "downloads"),
        ]
        let query = query.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { components.queryItems?.append(URLQueryItem(name: "search", value: query)) }
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode([ListedModel].self, from: data)
            .filter { !$0.id.localizedCaseInsensitiveContains("embedding") }
    }

    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDownloadTask?
        private var isCancelled = false
        var observation: NSKeyValueObservation?

        /// Cancels right away if cancellation was requested before the task existed.
        func set(_ task: URLSessionDownloadTask) {
            let cancelNow = lock.withLock { () -> Bool in
                self.task = task
                return isCancelled
            }
            if cancelNow { task.cancel() }
        }

        func cancel() {
            let task = lock.withLock { () -> URLSessionDownloadTask? in
                isCancelled = true
                return self.task
            }
            task?.cancel()
        }
    }

    private static func downloadFile(
        _ url: URL, to target: URL, onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let box = TaskBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = URLSession.shared.downloadTask(with: url) { temporary, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let temporary, (response as? HTTPURLResponse)?.statusCode == 200 else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                        return
                    }
                    do {
                        try? FileManager.default.removeItem(at: target)
                        try FileManager.default.moveItem(at: temporary, to: target)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.observation = task.observe(\.countOfBytesReceived) { task, _ in
                    onBytes(task.countOfBytesReceived)
                }
                task.resume()
                box.set(task)
            }
        } onCancel: {
            box.cancel()
        }
    }

    enum DownloadError: LocalizedError {
        case repositoryNotFound(String)
        case noWeights(String)
        case unsupported(String)
        case corrupted(String)

        var errorDescription: String? {
            switch self {
            case .corrupted(let file): return "「\(file)」が正しくダウンロードできませんでした。もう一度お試しください。"
            case .unsupported(let repo): return "「\(repo)」はこのアプリが対応していない種類のモデルです。"
            case .repositoryNotFound(let repo): return "モデル「\(repo)」が見つかりません。"
            case .noWeights(let repo): return "「\(repo)」は MLX 形式 (safetensors) のモデルではありません。"
            }
        }
    }
}

enum ModelState: Equatable {
    case notDownloaded
    case downloading(Double)
    case downloaded
}
