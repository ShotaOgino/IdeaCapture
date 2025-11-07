import SwiftUI
import UIKit

struct HistoryView: View {
    @ObservedObject var viewModel: RecorderViewModel
    @Environment(\.dismiss) private var dismiss
    private static let sectionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()

    private var groupedHistory: [(date: Date, entries: [TranscriptEntry])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: viewModel.history) { entry in
            calendar.startOfDay(for: entry.createdAt)
        }

        return grouped
            .map { date, entries in
                (date: date, entries: entries.sorted(by: { $0.createdAt > $1.createdAt }))
            }
            .sorted(by: { $0.date > $1.date })
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.history.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "tray")
                            .font(.system(size: 44))
                            .foregroundColor(.secondary)
                        Text("まだ保存された録音はありません")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text("録音を完了すると、ここに文字起こしが保存されます。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground))
                } else {
                    List {
                        ForEach(groupedHistory, id: \.date) { section in
                            Section {
                                ForEach(section.entries) { entry in
                                    NavigationLink(value: entry.id) {
                                        HistoryRow(entry: entry)
                                    }
                                    .contextMenu {
                                        Button {
                                            UIPasteboard.general.string = entry.text
                                        } label: {
                                            Label("コピー", systemImage: "doc.on.doc")
                                        }
                                    }
                                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                        Button {
                                            viewModel.toggleReadState(for: entry)
                                        } label: {
                                            if entry.isRead {
                                                Label("未読にする", systemImage: "envelope.badge")
                                            } else {
                                                Label("既読にする", systemImage: "envelope.open")
                                            }
                                        }
                                        .tint(entry.isRead ? .blue : .green)
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            viewModel.deleteEntry(entry)
                                        } label: {
                                            Label("削除", systemImage: "trash")
                                        }
                                    }
                                }
                            } header: {
                                Text(Self.sectionDateFormatter.string(from: section.date))
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("履歴")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if viewModel.unreadCount > 0 {
                        Button("すべて既読") {
                            viewModel.markAllAsRead()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
            }
            .navigationDestination(for: UUID.self) { entryID in
                TranscriptDetailView(entryID: entryID, viewModel: viewModel)
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: TranscriptEntry

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(entry.isRead ? Color.clear : Color.blue)
                .frame(width: 10, height: 10)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(Self.dateFormatter.string(from: entry.createdAt))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(entry.previewText)
                    .font(entry.isRead ? .body : .body.weight(.semibold))
                    .foregroundColor(entry.isRead ? .primary.opacity(0.75) : .primary)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(.vertical, 6)
    }
}

private struct TranscriptDetailView: View {
    let entryID: UUID
    @ObservedObject var viewModel: RecorderViewModel
    @Environment(\.dismiss) private var dismiss

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter
    }()

    private var entry: TranscriptEntry? {
        viewModel.entry(with: entryID)
    }

    var body: some View {
        Group {
            if let entry = entry {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(Self.dateFormatter.string(from: entry.createdAt))
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text(entry.text)
                            .font(.body)
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = entry.text
                                } label: {
                                    Label("コピー", systemImage: "doc.on.doc")
                                }
                            }
                    }
                    .padding()
                }
                .background(Color(.systemBackground))
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        ShareLink(item: entry.text) {
                            Label("シェア", systemImage: "square.and.arrow.up")
                                .labelStyle(.iconOnly)
                        }

                        Button {
                            viewModel.toggleReadState(for: entry)
                            dismiss()
                        } label: {
                            Label(
                                entry.isRead ? "未読にする" : "既読にする",
                                systemImage: entry.isRead ? "envelope.badge" : "envelope.open"
                            )
                            .labelStyle(.iconOnly)
                        }

                        Button(role: .destructive) {
                            viewModel.deleteEntry(entry)
                            dismiss()
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                    }
                }
                .onAppear {
                    viewModel.markAsRead(entry)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 44))
                        .foregroundColor(.secondary)
                    Text("この記録は見つかりません")
                        .font(.headline)
                    Text("履歴から削除された可能性があります。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
            }
        }
    }
}
