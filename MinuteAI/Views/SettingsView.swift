import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            TranscriptionSettings()
                .tabItem { Label("文字起こし", systemImage: "waveform") }
            SummarySettings()
                .tabItem { Label("要約", systemImage: "sparkles") }
            CategorySettings()
                .tabItem { Label("カテゴリ", systemImage: "tag") }
            StorageSettings()
                .tabItem { Label("データ", systemImage: "internaldrive") }
        }
        .frame(width: 680, height: 620)
    }
}

private struct ModelRow: View {
    let name: String
    let detail: String
    let state: ModelState
    let selected: Bool
    var fit: ModelFit?
    var recommended = false
    let select: () -> Void
    let download: () -> Void
    let cancel: () -> Void
    let delete: () -> Void
    /// Takes a model that is not downloaded off the list (models added by hand or from the search).
    var remove: (() -> Void)?
    /// The model may be in use: it can't be deleted right now. Downloads can still be started and cancelled.
    var locked = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: select) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(state != .downloaded)
            .help(state == .downloaded ? "このモデルを使用する" : "ダウンロードすると選択できます")
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            FitBadge(fit: fit, recommended: recommended)
            switch state {
            case .notDownloaded:
                Button("ダウンロード", action: download)
                if let remove {
                    Button("一覧から削除", action: remove)
                        .disabled(locked)
                }
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 90)
                Text("\(Int(fraction * 100))%").font(.caption.monospacedDigit()).frame(width: 34, alignment: .trailing)
                Button("中止", action: cancel)
            case .downloaded:
                Button("削除", role: .destructive, action: delete)
                    .disabled(locked)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct TranscriptionSettings: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section("文字起こしモデル") {
                ForEach(WhisperModelManager.catalog) { model in
                    ModelRow(
                        name: model.name, detail: model.detail, state: app.whisper.state(model.variant),
                        selected: settings.whisperVariant == model.variant,
                        select: { settings.whisperVariant = model.variant },
                        download: {
                            app.whisper.download(model.variant)
                            if app.whisper.state(settings.whisperVariant) == .notDownloaded {
                                settings.whisperVariant = model.variant
                            }
                        },
                        cancel: { app.whisper.cancelDownload(model.variant) },
                        delete: { app.whisper.delete(model.variant) })
                    .disabled(app.recording.isBusy)
                }
                if let error = app.whisper.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section("認識") {
                Picker("言語", selection: $settings.language) {
                    Text("日本語").tag("ja")
                    Text("英語").tag("en")
                    Text("自動判定").tag("auto")
                }
            }
            Section("録音する音声") {
                Toggle("マイク(自分の声・会議室の音声)", isOn: $settings.captureMicrophone)
                Toggle("システム音声(リモート会議の相手の声)", isOn: $settings.captureSystemAudio)
            }
            .disabled(app.recording.isBusy)
        }
        .formStyle(.grouped)
    }
}

private struct SummarySettings: View {
    @Environment(AppState.self) private var app
    @State private var query = ""
    @State private var customID = ""

    private let specs = DeviceSpecs.current

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                LabeledContent("チップ", value: specs.chip)
                LabeledContent("CPU", value: specs.performanceCores > 0
                    ? "\(specs.cores)コア(高性能 \(specs.performanceCores) + 高効率 \(specs.efficiencyCores))"
                    : "\(specs.cores)コア")
                LabeledContent("メモリ", value: gb(specs.memoryGB, digits: 0))
                if let gpu = specs.gpuMemoryGB {
                    LabeledContent("GPUが使えるメモリ(VRAM相当)", value: gb(gpu))
                }
                if let free = specs.freeDiskGB {
                    LabeledContent("ディスクの空き", value: gb(free, digits: 0))
                }
            } header: {
                Text("このMacのスペック")
            } footer: {
                Text("Apple Silicon では GPU 専用のメモリはなく、メインメモリを共有します。このMacでは約\(gb(specs.comfortableModelGB))までのモデルが快適、約\(gb(specs.largestModelGB))までが動作の目安です。")
            }

            Section {
                ForEach(app.llm.models) { model in
                    ModelRow(
                        name: model.name, detail: detail(model), state: app.llm.state(model.id),
                        selected: settings.llmModelID == model.id,
                        fit: specs.fit(sizeGB: model.sizeGB), recommended: app.llm.recommendedID == model.id,
                        select: { settings.llmModelID = model.id },
                        download: {
                            app.llm.download(model.id)
                            if app.llm.state(settings.llmModelID) == .notDownloaded {
                                settings.llmModelID = model.id
                            }
                        },
                        cancel: { app.llm.cancelDownload(model.id) },
                        delete: { app.llm.delete(model.id) },
                        remove: app.llm.added.contains(model) ? { app.llm.delete(model.id) } : nil,
                        locked: app.isModelBusy)
                }
                if let error = app.llm.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("要約モデル")
            } footer: {
                Text("◉ を付けたモデルが既定になります。会議ごとのモデルは、各会議の「要約」タブで選べます。")
            }

            Section {
                HStack {
                    TextField("キーワード(例: gemma, qwen)", text: $query)
                        .labelsHidden()
                        .onSubmit { app.llm.search(query) }
                    Button(app.llm.searchResults.isEmpty ? "一覧を取得" : "再取得") { app.llm.search(query) }
                        .disabled(app.llm.isSearching)
                    if app.llm.isSearching { ProgressView().controlSize(.small) }
                }
                if let error = app.llm.searchError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                ForEach(app.llm.searchResults.filter { result in !app.llm.models.contains { $0.id == result.id } }) { model in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.name).fontWeight(.medium)
                            Text(detail(model)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        FitBadge(fit: specs.fit(sizeGB: model.sizeGB), recommended: false)
                        Button("追加してダウンロード") { app.llm.add(model) }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Hugging Face から探す")
            } footer: {
                Text("mlx-community が公開している MLX 形式のモデルのうち、このアプリで動かせるものをダウンロード数の多い順に表示します。一覧の取得時だけ Hugging Face に接続します。")
            }

            Section("リポジトリ名を指定して追加") {
                HStack {
                    TextField("mlx-community/モデル名", text: $customID)
                        .labelsHidden()
                    Button("追加してダウンロード") {
                        app.llm.addCustom(customID)
                        customID = ""
                    }
                    .disabled(!customID.contains("/"))
                }
            }
        }
        .formStyle(.grouped)
    }

    private func detail(_ model: LLMModelInfo) -> String {
        var parts: [String] = []
        if let size = model.sizeGB { parts.append("約\(gb(size))") }
        if !model.detail.isEmpty { parts.append(model.detail) }
        if let downloads = model.downloads { parts.append("\(downloads.formatted()) ダウンロード") }
        parts.append(model.id)
        return parts.joined(separator: "・")
    }

    private func gb(_ value: Double, digits: Int = 1) -> String {
        "\(value.formatted(.number.precision(.fractionLength(digits))))GB"
    }
}

/// Tells at a glance whether a model suits this Mac.
private struct FitBadge: View {
    let fit: ModelFit?
    let recommended: Bool

    var body: some View {
        if let fit {
            let color: Color = fit == .comfortable ? .green : fit == .heavy ? .orange : .red
            Text(recommended ? "推奨" : fit.label)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(color.opacity(recommended ? 0.85 : 0.18)))
                .foregroundStyle(recommended ? Color.white : color)
                .help(help(fit))
        }
    }

    private func help(_ fit: ModelFit) -> String {
        switch fit {
        case .comfortable: return recommended ? "このMacで快適に動く中で最も高品質なモデルです" : "このMacで快適に動きます"
        case .heavy: return "動きますが、メモリに余裕がなく遅くなることがあります"
        case .tooLarge: return "このMacのメモリには大きすぎます"
        }
    }
}

private struct CategorySettings: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                ForEach($settings.categories) { $category in
                    HStack {
                        Picker("", selection: $category.colorName) {
                            ForEach(NoteCategory.palette, id: \.self) { name in
                                Image(systemName: "circle.fill")
                                    .foregroundStyle(NoteCategory(id: "", name: "", colorName: name).color)
                                    .tag(name)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        TextField("カテゴリ名", text: $category.name)
                            .labelsHidden()
                        Button {
                            settings.categories.removeAll { $0.id == category.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(settings.categories.count <= 1)
                        .help("カテゴリを削除")
                    }
                }
                Button("カテゴリを追加") {
                    settings.categories.append(
                        NoteCategory(id: UUID().uuidString, name: "新しいカテゴリ", colorName: "purple"))
                }
            } header: {
                Text("メモのカテゴリ")
            } footer: {
                Text("「タスク」カテゴリのメモには完了チェックが付きます。カテゴリは要約にも反映されます。")
            }
            Section {
                Button("初期状態に戻す") { settings.categories = NoteCategory.defaults }
            }
        }
        .formStyle(.grouped)
    }
}

private struct StorageSettings: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("保存先") {
                    Text(MeetingStore.rootURL.path)
                        .font(.caption)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                Button("Finder で表示") {
                    NSWorkspace.shared.activateFileViewerSelecting([MeetingStore.rootURL])
                }
            } header: {
                Text("データの保存場所")
            } footer: {
                Text("録音・文字起こし・メモ・要約はすべてこのMacの中だけに保存され、文字起こしと要約もMac上で処理されます。インターネットに接続するのは、モデルをダウンロードするときだけです。")
            }
        }
        .formStyle(.grouped)
    }
}
