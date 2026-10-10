import SwiftUI

@main
struct MinuteAIApp: App {
    @State private var app = AppState()

    var body: some Scene {
        Window("MinuteAI", id: "main") {
            ContentView()
                .environment(app)
                .frame(minWidth: 980, minHeight: 600)
                #if DEBUG
                .task { SelfTest.runIfRequested(app) }
                #endif
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    app.willTerminate()
                }
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
