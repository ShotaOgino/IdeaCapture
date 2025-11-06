import SwiftUI

@main
struct IdeaCaptureApp: App {
    init() {
        PerformanceMonitor.shared.startLaunchMeasurement()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    PerformanceMonitor.shared.endLaunchMeasurement()
                    PerformanceMonitor.shared.startMonitoring()
                }
                .onOpenURL { url in
                    guard url.scheme == "ideacapture" else { return }

                    if url.host == "start" {
                        RecorderViewModel.scheduleGlobalStartRequest()
                        NotificationCenter.default.post(name: .startRecording, object: nil)
                    }
                }
        }
    }
}
