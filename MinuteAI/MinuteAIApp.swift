import SwiftUI

@main
struct MinuteAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState.shared

    var body: some Scene {
        Window("MinuteAI", id: "main") {
            ContentView()
                .environment(app)
                .frame(minWidth: 980, minHeight: 600)
                #if DEBUG
                .task { SelfTest.runIfRequested(app) }
                #endif
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新しい会議") { app.newMeeting() }
                    .keyboardShortcut("n")
            }
        }

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}

/// Handles quitting at the application level, so it works no matter which window is open or closed.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Longest the app waits for the last transcription before quitting anyway.
    private static let quitTimeout: TimeInterval = 60

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the window must not end a meeting that is being recorded.
        !AppState.shared.recording.isBusy
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let recording = AppState.shared.recording
        switch recording.phase {
        case .idle:
            // Changes that cannot be written exist only in memory: don't let them vanish unnoticed.
            let store = AppState.shared.store
            store.flush()
            guard store.saveError != nil else { return .terminateNow }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "保存できていない変更があります"
            alert.informativeText = "会議の内容をディスクに保存できませんでした。このまま終了すると、保存できていない変更は失われます。"
            alert.addButton(withTitle: "キャンセル")
            alert.addButton(withTitle: "終了")
            return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
        case .recording:
            let alert = NSAlert()
            alert.messageText = "録音中です"
            alert.informativeText = "録音を停止し、残りの音声を文字起こししてから終了します。"
            alert.addButton(withTitle: "停止して終了")
            alert.addButton(withTitle: "キャンセル")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            Task { await recording.stop() }
        case .preparing:
            recording.cancelStart()
        case .finishing:
            break
        }
        Task {
            // The audio file is closed as soon as recording stops; this only waits for the remaining
            // transcription (or for a start that is being abandoned), and not forever.
            let deadline = Date().addingTimeInterval(Self.quitTimeout)
            while recording.phase != .idle, Date() < deadline {
                if recording.phase == .recording { Task { await recording.stop() } }
                try? await Task.sleep(for: .milliseconds(100))
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.willTerminate()
    }
}
