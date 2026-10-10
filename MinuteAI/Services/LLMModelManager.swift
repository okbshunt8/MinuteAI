import Foundation
import MLXLLM
import Observation

struct LLMModelInfo: Identifiable, Hashable, Codable {
    /// Hugging Face repository of an MLX-format model.
    let id: String
    let name: String
    let detail: String
    /// Download size, which is also roughly the memory the model needs.
    var sizeGB: Double?
    var downloads: Int?
}

/// Downloads and deletes the local language models used for summaries.
@MainActor
@Observable
final class LLMModelManager {
    static let catalog: [LLMModelInfo] = [
        LLMModelInfo(id: "mlx-community/gemma-4-e4b-it-4bit", name: "Gemma 4 E4B",
                     detail: "日本語の要約品質が高い", sizeGB: 5.2),
        LLMModelInfo(id: "mlx-community/gemma-4-e2b-it-4bit", name: "Gemma 4 E2B",
                     detail: "軽量で高速", sizeGB: 3.6),
        LLMModelInfo(id: "mlx-community/Qwen3-4B-4bit", name: "Qwen3 4B",
                     detail: "小さめで高速", sizeGB: 2.3),
    ]

    private(set) var states: [String: ModelState] = [:]
    private(set) var lastError: String?
    /// Models added from the Hugging Face search or by repository id.
    private(set) var added: [LLMModelInfo]

    private(set) var searchResults: [LLMModelInfo] = []
    private(set) var isSearching = false
    private(set) var searchError: String?

    @ObservationIgnored private var downloads: [String: Task<Void, Never>] = [:]

    private static var baseURL: URL { MeetingStore.modelsURL.appendingPathComponent("LLM", isDirectory: true) }

    static func folder(for id: String) -> URL {
        baseURL.appendingPathComponent(id.replacingOccurrences(of: "/", with: "__"), isDirectory: true)
    }

    static func name(_ id: String) -> String {
        catalog.first { $0.id == id }?.name ?? id.split(separator: "/").last.map(String.init) ?? id
    }

    var models: [LLMModelInfo] { Self.catalog + added }

    var downloadedModels: [LLMModelInfo] { models.filter { state($0.id) == .downloaded } }

    /// The best-quality built-in model that runs comfortably on this Mac.
    var recommendedID: String? {
        let specs = DeviceSpecs.current
        return Self.catalog.first { specs.fit(sizeGB: $0.sizeGB) == .comfortable }?.id
    }

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "addedLLMModels"),
           let saved = try? JSONDecoder().decode([LLMModelInfo].self, from: data) {
            added = saved
        } else {
            // Models added before sizes were stored.
            added = (defaults.stringArray(forKey: "customLLMModels") ?? []).map {
                LLMModelInfo(id: $0, name: Self.name($0), detail: "追加したモデル")
            }
        }
        for model in models {
            states[model.id] = HFDownloader.isComplete(Self.folder(for: model.id)) ? .downloaded : .notDownloaded
        }
    }

    func state(_ id: String) -> ModelState { states[id] ?? .notDownloaded }

    /// Adds a model to the list and starts downloading it.
    func add(_ model: LLMModelInfo) {
        guard !models.contains(where: { $0.id == model.id }) else { return }
        added.append(model)
        saveAdded()
        download(model.id)
    }

    func addCustom(_ id: String) {
        let id = id.trimmingCharacters(in: .whitespaces)
        guard id.contains("/") else { return }
        add(LLMModelInfo(id: id, name: Self.name(id), detail: "追加したモデル"))
    }

    func download(_ id: String) {
        guard downloads[id] == nil, state(id) == .notDownloaded else { return }
        states[id] = .downloading(0)
        lastError = nil
        downloads[id] = Task {
            do {
                // Find out before fetching gigabytes whether this app can run the model at all.
                if !Self.catalog.contains(where: { $0.id == id }) {
                    guard let type = try await HFDownloader.modelType(repo: id),
                          await LLMTypeRegistry.shared.contains(type)
                    else { throw HFDownloader.DownloadError.unsupported(id) }
                }
                try await HFDownloader.download(repo: id, to: Self.folder(for: id)) { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.state(id) else { return }
                        self.states[id] = .downloading(fraction)
                    }
                }
                states[id] = .downloaded
            } catch {
                states[id] = .notDownloaded
                if !Task.isCancelled { lastError = "ダウンロードに失敗しました: \(error.localizedDescription)" }
            }
            downloads[id] = nil
        }
    }

    func cancelDownload(_ id: String) {
        downloads[id]?.cancel()
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: Self.folder(for: id))
        states[id] = .notDownloaded
        if added.contains(where: { $0.id == id }) {
            added.removeAll { $0.id == id }
            states[id] = nil
            saveAdded()
        }
    }

    /// Looks up MLX models on Hugging Face that this app can run, most downloaded first.
    func search(_ query: String) {
        guard !isSearching else { return }
        isSearching = true
        searchError = nil
        Task {
            do {
                var results: [LLMModelInfo] = []
                for candidate in try await HFDownloader.listModels(query: query) {
                    guard let type = candidate.modelType, await LLMTypeRegistry.shared.contains(type) else { continue }
                    results.append(LLMModelInfo(
                        id: candidate.id, name: Self.name(candidate.id), detail: "",
                        sizeGB: nil, downloads: candidate.downloads))
                    if results.count == 25 { break }
                }
                let sizes = await HFDownloader.sizes(repos: results.map(\.id))
                searchResults = results.map { model in
                    var model = model
                    model.sizeGB = sizes[model.id].map { Double($0) / 1_000_000_000 }
                    return model
                }
                if results.isEmpty { searchError = "対応しているモデルが見つかりませんでした。" }
            } catch {
                searchError = "一覧を取得できませんでした: \(error.localizedDescription)"
            }
            isSearching = false
        }
    }

    private func saveAdded() {
        if let data = try? JSONEncoder().encode(added) {
            UserDefaults.standard.set(data, forKey: "addedLLMModels")
        }
    }
}
