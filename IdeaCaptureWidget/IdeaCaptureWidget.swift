import WidgetKit
import SwiftUI

struct IdeaCaptureEntry: TimelineEntry {
    let date: Date
}

struct IdeaCaptureProvider: TimelineProvider {
    func placeholder(in context: Context) -> IdeaCaptureEntry {
        IdeaCaptureEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (IdeaCaptureEntry) -> Void) {
        completion(IdeaCaptureEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<IdeaCaptureEntry>) -> Void) {
        let entry = IdeaCaptureEntry(date: Date())
        let refreshDate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        let timeline = Timeline(entries: [entry], policy: .after(refreshDate))
        completion(timeline)
    }
}

struct IdeaCaptureWidgetEntryView: View {
    var entry: IdeaCaptureProvider.Entry

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.9, green: 0.0, blue: 0.2),
                    Color(red: 0.6, green: 0.0, blue: 0.15)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)

                Text("IdeaCapture")
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.9))

                Text("タップして録音開始")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.75))
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
        }
        .widgetURL(URL(string: "ideacapture://start"))
    }
}

struct IdeaCaptureAccessoryWidgetEntryView: View {
    var entry: IdeaCaptureProvider.Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if family == .accessoryInline {
                Label("録音開始", systemImage: "mic.fill")
            } else {
                ZStack {
                    AccessoryWidgetBackground()
                    HStack(spacing: 4) {
                        Image(systemName: "mic.fill")
                        Text("録音を開始")
                    }
                    .foregroundColor(.white)
                }
            }
        }
        .widgetURL(URL(string: "ideacapture://start"))
    }
}
