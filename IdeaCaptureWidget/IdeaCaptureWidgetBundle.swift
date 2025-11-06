import WidgetKit
import SwiftUI

@main
struct IdeaCaptureWidgetBundle: WidgetBundle {
    @WidgetBundleBuilder
    var body: some Widget {
        IdeaCaptureLockScreenWidget()
        IdeaCaptureRectangularWidget()
    }
}

struct IdeaCaptureRectangularWidget: Widget {
    private let kind = "IdeaCaptureRectangularWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: IdeaCaptureProvider()) { entry in
            IdeaCaptureWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("IdeaCapture")
        .description("ロック画面やホーム画面から録音を開始できます。")
        .supportedFamilies([.systemSmall])
    }
}

struct IdeaCaptureLockScreenWidget: Widget {
    private let kind = "IdeaCaptureLockScreenWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: IdeaCaptureProvider()) { entry in
            IdeaCaptureAccessoryWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("録音ショートカット")
        .description("ロック画面からワンタップで録音を開始します。")
        .supportedFamilies([.accessoryRectangular, .accessoryInline])
    }
}
