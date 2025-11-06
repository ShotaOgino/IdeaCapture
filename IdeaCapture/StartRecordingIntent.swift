import AppIntents
import SwiftUI

struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "IdeaCapture を開始"
    static var description = IntentDescription("IdeaCapture でアイデアの録音を開始します。")

    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // Post notification to start recording
        NotificationCenter.default.post(name: .startRecording, object: nil)

        return .result()
    }
}

struct IdeaCaptureShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "\(.applicationName) を起動",
                "\(.applicationName) で録音を開始",
                "アイデアを \(.applicationName) で録音",
                "\(.applicationName) で録音して"
            ],
            shortTitle: "録音を開始",
            systemImageName: "mic.fill"
        )
    }
}

extension Notification.Name {
    static let startRecording = Notification.Name("startRecording")
}
