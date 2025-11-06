import AppIntents
import SwiftUI

struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start IdeaCapture"
    static var description = IntentDescription("Start recording your ideas with IdeaCapture")

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
                "Start \(.applicationName)",
                "Start recording with \(.applicationName)",
                "Record idea with \(.applicationName)",
                "Capture idea with \(.applicationName)"
            ],
            shortTitle: "Start Recording",
            systemImageName: "mic.fill"
        )
    }
}

extension Notification.Name {
    static let startRecording = Notification.Name("startRecording")
}
