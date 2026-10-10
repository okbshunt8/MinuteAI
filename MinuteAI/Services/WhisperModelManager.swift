import Foundation
import Observation
import WhisperKit

struct WhisperModelInfo: Identifiable, Hashable {
    let variant: String
    let name: String
    let detail: String
    var id: String { variant }
}

/// Downloads, deletes and loads the speech-to-text models (Whisper, converted to Core ML).
@MainActor
@Observable
final class WhisperModelManager {
    static let catalog: [WhisperModelInfo] = [
        WhisperModelInfo(variant: "openai_whisper-large-v3-v20240930_626MB", name: "Large v3 Turbo (圧縮版)",
                         detail: "約630MB・推奨。日本語の精度と速度のバランスが良い"),
        WhisperModelInfo(variant: "openai_whisper-large-v3_947MB", name: "Large v3 (圧縮版)",
                         detail: "約950MB・最も高精度だが処理は重め"),
        WhisperModelInfo(variant: "openai_whisper-small_216MB", name: "Small (圧縮版)",
                         detail: "約220MB・軽量。精度は控えめ"),
        WhisperModelInfo(variant: "openai_whisper-base", name: "Base",
                         detail: "約150MB・最軽量。動作確認向け"),
    ]

    static func name(_ variant: String) -> String {
        catalog.first { $0.variant == variant }?.name ?? variant
    }

    private(set) var states: [String: ModelState] = [:]
    private(set) var lastError: String?

    @ObservationIgnored private var kit: WhisperKit?
    @ObservationIgnored private var loadedVariant: String?
    @ObservationIgnored private var downloads: [String: Task<Void, Never>] = [:]

    private static var baseURL: URL { MeetingStore.modelsURL.appendingPathComponent("Whisper", isDirectory: true) }

    init() {
        for model in Self.catalog {
            states[model.variant] = folder(for: model.variant) != nil ? .downloaded : .notDownloaded
        }
    }

    func state(_ variant: String) -> ModelState { states[variant] ?? .notDownloaded }

    var downloadedModels: [WhisperModelInfo] { Self.catalog.filter { state($0.variant) == .downloaded } }

    private func folder(for variant: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: "whisperFolder.\(variant)"),
              FileManager.default.fileExists(atPath: path)
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    func download(_ variant: String) {
        guard downloads[variant] == nil, state(variant) == .notDownloaded else { return }
        states[variant] = .downloading(0)
        lastError = nil
        downloads[variant] = Task {
            do {
                try FileManager.default.createDirectory(at: Self.baseURL, withIntermediateDirectories: true)
                let folder = try await WhisperKit.download(variant: variant, downloadBase: Self.baseURL) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.state(variant) else { return }
                        self.states[variant] = .downloading(progress.fractionCompleted)
                    }
                }
                UserDefaults.standard.set(folder.path, forKey: "whisperFolder.\(variant)")
                states[variant] = .downloaded
            } catch {
                states[variant] = .notDownloaded
                if !Task.isCancelled { lastError = "ダウンロードに失敗しました: \(error.localizedDescription)" }
            }
            downloads[variant] = nil
        }
    }

    func cancelDownload(_ variant: String) {
        downloads[variant]?.cancel()
    }

    func delete(_ variant: String) {
        if loadedVariant == variant {
            kit = nil
            loadedVariant = nil
        }
        if let folder = folder(for: variant) { try? FileManager.default.removeItem(at: folder) }
        UserDefaults.standard.removeObject(forKey: "whisperFolder.\(variant)")
        states[variant] = .notDownloaded
    }

    /// Returns a loaded model for the variant. The model must already be downloaded.
    func load(_ variant: String) async throws -> WhisperKit {
        if let kit, loadedVariant == variant { return kit }
        guard let folder = folder(for: variant) else { throw TranscriptionError.modelNotDownloaded }
        kit = nil
        loadedVariant = nil
        let config = WhisperKitConfig(
            model: variant, modelFolder: folder.path, verbose: false, logLevel: .error,
            prewarm: false, load: true, download: false)
        let loaded = try await WhisperKit(config)
        kit = loaded
        loadedVariant = variant
        return loaded
    }
}

enum TranscriptionError: LocalizedError {
    case modelNotDownloaded

    var errorDescription: String? {
        "文字起こしモデルがダウンロードされていません。設定 > 文字起こし からダウンロードしてください。"
    }
}
