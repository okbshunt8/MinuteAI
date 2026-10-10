import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers

/// Writes the meeting summary with a language model running in-process (MLX). No network involved.
enum Summarizer {
    enum Event {
        case status(String)
        /// The summary text generated so far.
        case text(String)
    }

    enum SummaryError: LocalizedError {
        case modelNotDownloaded
        case nothingToSummarize

        var errorDescription: String? {
            switch self {
            case .modelNotDownloaded:
                return "要約モデルがダウンロードされていません。設定 > 要約 からダウンロードしてください。"
            case .nothingToSummarize:
                return "要約する文字起こしやメモがありません。"
            }
        }
    }

    private static let system = "あなたは会議の議事録を作成する有能なアシスタントです。事実に忠実に、簡潔な日本語で書きます。"
    /// Transcripts longer than this are summarized part by part first.
    private static let singlePassLimit = 14_000
    private static let partSize = 9_000

    static func summarize(
        meeting: Meeting, categories: [NoteCategory], modelFolder: URL
    ) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(meeting: meeting, categories: categories, modelFolder: modelFolder) {
                        continuation.yield($0)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                // Give the model's memory back; the next recording needs it more than we do.
                Memory.clearCache()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(
        meeting: Meeting, categories: [NoteCategory], modelFolder: URL, emit: (Event) -> Void
    ) async throws {
        guard HFDownloader.isComplete(modelFolder) else { throw SummaryError.modelNotDownloaded }
        let lines = meeting.segments.map { segment in
            let chapter = segment.chapterTitle.flatMap { $0.isEmpty ? nil : "【章: \($0)】\n" } ?? ""
            return "\(chapter)[\(formatTime(segment.start))]\(segment.marker != nil ? "【重要】" : "") \(segment.text)"
        }
        let notes = notesText(meeting.notes, categories: categories)
        guard !lines.isEmpty || !notes.isEmpty else { throw SummaryError.nothingToSummarize }

        emit(.status("要約モデルを読み込み中…"))
        let container = try await loadModelContainer(from: modelFolder, using: #huggingFaceTokenizerLoader())

        var transcript = lines.joined(separator: "\n")
        if transcript.count > singlePassLimit {
            let parts = split(lines)
            var digests: [String] = []
            for (index, part) in parts.enumerated() {
                try Task.checkCancellation()
                emit(.status("文字起こしを整理中… (\(index + 1)/\(parts.count))"))
                let prompt = """
                以下は会議の文字起こしの一部(パート\(index + 1)/\(parts.count))です。音声認識の結果なので誤字を含みます。
                重要な論点・決定事項・課題・タスクを、日本語の箇条書きで漏れなく抽出してください。
                【重要】と付いた発言は参加者がマーカーを付けた箇所なので必ず含めてください。前置きは不要です。

                \(part)
                """
                let digest = try await generate(container, prompt: prompt, maxTokens: 900) { _ in }
                digests.append("### パート\(index + 1)\n\(digest)")
            }
            transcript = digests.joined(separator: "\n\n")
        }

        try Task.checkCancellation()
        emit(.status("要約を生成中…"))
        let prompt = """
        以下は会議「\(meeting.title)」の文字起こしと、参加者が会議中に書いたメモです。これらをもとに議事録の要約を作成してください。

        # ルール
        - 文字起こしは音声認識の結果で誤認識を含みます。文脈から自然に解釈してください。
        - 【重要】と付いた発言は参加者がマーカーを付けた箇所です。必ず要約に反映してください。
        - 【章: 〜】は話題の区切りを示す見出しです。議論の整理に使ってください。
        - 参加者のメモは最も信頼できる情報です。カテゴリに従って該当するセクションに必ず反映してください。
        - 文字起こしやメモにない内容を創作しないでください。該当がないセクションには「なし」と書いてください。
        - 前置きや締めの挨拶は書かず、下記の形式のMarkdownだけを出力してください。

        # 出力形式
        ## 概要
        (会議の目的と結論を3〜5文で)
        ## 主な議論
        - (論点ごとの箇条書き)
        ## 決定事項
        - ...
        ## 課題
        - ...
        ## タスク
        - 内容(担当・期限が分かれば併記)

        # 参加者のメモ
        \(notes.isEmpty ? "(なし)" : notes)

        # 文字起こし
        \(transcript.isEmpty ? "(なし)" : transcript)
        """
        _ = try await generate(container, prompt: prompt, maxTokens: 2500) { emit(.text($0)) }
    }

    private static func generate(
        _ container: ModelContainer, prompt: String, maxTokens: Int, temperature: Float = 0.3,
        onText: (String) -> Void
    ) async throws -> String {
        let session = ChatSession(
            container, instructions: system,
            generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: temperature))
        var raw = ""
        for try await chunk in session.streamResponse(to: prompt) {
            try Task.checkCancellation()
            raw += chunk
            onText(clean(raw))
        }
        return clean(raw)
    }

    /// Removes the reasoning block some models print before the answer.
    private static func clean(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "<think>") {
            if let close = result.range(of: "</think>", range: open.upperBound..<result.endIndex) {
                result.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                result.removeSubrange(open.lowerBound..<result.endIndex)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func notesText(_ notes: [Note], categories: [NoteCategory]) -> String {
        notes.map { note in
            let category = categories.first { $0.id == note.categoryID }?.name ?? "メモ"
            let time = note.time.map { " (\(formatTime($0)))" } ?? ""
            let done = note.categoryID == NoteCategory.taskID && note.done ? " [完了]" : ""
            return "- [\(category)]\(time)\(done) \(note.text.replacingOccurrences(of: "\n", with: " "))"
        }
        .joined(separator: "\n")
    }

    private static func split(_ lines: [String]) -> [String] {
        var parts: [String] = []
        var current = ""
        for line in lines {
            if !current.isEmpty, current.count + line.count > partSize {
                parts.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}

// MARK: - Chapters

extension Summarizer {
    struct ChapterStart {
        let segmentID: UUID
        let title: String
    }

    /// Reads the whole transcript and proposes where each topic starts and what to call it.
    static func chapters(
        meeting: Meeting, modelFolder: URL, status: @escaping @Sendable (String) -> Void
    ) async throws -> [ChapterStart] {
        defer { Memory.clearCache() }
        guard HFDownloader.isComplete(modelFolder) else { throw SummaryError.modelNotDownloaded }
        let segments = meeting.segments
        guard !segments.isEmpty else { throw SummaryError.nothingToSummarize }

        status("モデルを読み込み中…")
        let container = try await loadModelContainer(from: modelFolder, using: #huggingFaceTokenizerLoader())

        // Long transcripts are read part by part; line numbers stay global so answers map back to lines.
        var parts: [Range<Int>] = []
        var partStart = 0
        var partLength = 0
        for (index, segment) in segments.enumerated() {
            if partLength > 0, partLength + segment.text.count > partSize {
                parts.append(partStart..<index)
                partStart = index
                partLength = 0
            }
            partLength += segment.text.count
        }
        parts.append(partStart..<segments.count)

        var result: [ChapterStart] = []
        for (partIndex, range) in parts.enumerated() {
            try Task.checkCancellation()
            status(parts.count > 1 ? "章立てを作成中… (\(partIndex + 1)/\(parts.count))" : "章立てを作成中…")
            let numbered = range.map { "[\($0 + 1)] \(segments[$0].text)" }.joined(separator: "\n")
            let continuation = result.last.map {
                "\n- 直前までの話題は「\($0.title)」です。冒頭でその話題が続いている場合は、話題が変わる行から章を始めてください。"
            } ?? "\n- 最初の章は行番号 \(range.lowerBound + 1) から始めてください。"
            let prompt = """
            以下は会議の文字起こしです(音声認識の結果なので誤字を含みます)。各行の先頭の [数字] は行番号です。
            話題が切り替わる位置で章に分け、各章が始まる行番号と見出しを出力してください。

            # ルール
            - 1行に1章、「行番号|見出し」の形式だけを出力する(例: 12|予算の見直し)。説明や前置きは書かない。
            - 章の開始行は、新しい話題を切り出している最初の発言にする。前の話題の締めの発言から始めない。
            - 見出しは、その章で何を話しているかが分かる具体的な日本語で、20文字以内にする。
            - 話題のまとまりごとに分け、細かく分けすぎない(目安: \(parts.count > 1 ? "1〜4章" : "2〜8章"))。\(continuation)

            # 文字起こし
            \(numbered)
            """
            let answer = try await generate(container, prompt: prompt, maxTokens: 400, temperature: 0) { _ in }
            for chapter in parseChapters(answer, in: range) where !result.contains(where: { $0.segmentID == segments[chapter.index].id }) {
                result.append(ChapterStart(segmentID: segments[chapter.index].id, title: chapter.title))
            }
        }
        return result
    }

    /// Reads "12|見出し" lines, ignoring anything that does not point at a line of this part.
    private static func parseChapters(_ answer: String, in range: Range<Int>) -> [(index: Int, title: String)] {
        var chapters: [(index: Int, title: String)] = []
        for line in answer.split(separator: "\n") {
            // Some models repeat the number ("12|12|見出し") or keep the brackets; accept those too.
            guard let match = line.firstMatch(of: /^\D{0,4}?(\d+)\]?\s*[|｜:：]\s*(?:\[?\d+\]?\s*[|｜:：]\s*)?(.+)$/),
                  let number = Int(match.1), range.contains(number - 1)
            else { continue }
            let title = String(match.2)
                .trimmingCharacters(in: CharacterSet(charactersIn: " 　「」\"*#|｜"))
            guard !title.isEmpty, !chapters.contains(where: { $0.index == number - 1 }) else { continue }
            chapters.append((number - 1, String(title.prefix(40))))
        }
        return chapters.sorted { $0.index < $1.index }
    }
}
