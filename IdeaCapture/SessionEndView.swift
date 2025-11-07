import SwiftUI
import UIKit

struct SessionEndView: View {
    @Binding var reviewText: String
    let onSaveEdits: (String) -> Void
    let onDismiss: () -> Void

    @State private var editedText: String = ""

    init(reviewText: Binding<String>, onSaveEdits: @escaping (String) -> Void, onDismiss: @escaping () -> Void) {
        _reviewText = reviewText
        self.onSaveEdits = onSaveEdits
        self.onDismiss = onDismiss
        _editedText = State(initialValue: reviewText.wrappedValue)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 30) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.2))
                        .frame(width: 100, height: 100)

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.green)
                }

                /* Text("録音を終了しました")
                    .font(.system(.title, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundColor(.white) */

                VStack(alignment: .leading, spacing: 10) {
                    Text("文字起こしを確認・修正できます")
                        .font(.system(.caption, design: .rounded))
                        .foregroundColor(.white.opacity(0.6))

                    TranscriptTextEditor(text: $editedText)
                        .frame(maxHeight: 220)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.white.opacity(0.08))
                        )
                        .onChange(of: reviewText) { newValue in
                            editedText = newValue
                        }
                }
                .padding(.horizontal, 30)

                Spacer()

                VStack(spacing: 12) {
                    Button(action: saveAndDismiss) {
                        Text("保存して終了")
                            .font(.system(.headline, design: .rounded))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.blue)
                            )
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 50)
            }
        }
        .onAppear {
            editedText = reviewText
        }
    }

private func saveAndDismiss() {
    onSaveEdits(editedText)
    onDismiss()
}
}

private struct TranscriptTextEditor: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.textColor = .white
        textView.tintColor = UIColor.systemBlue
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.keyboardAppearance = .dark
        textView.isScrollEnabled = true
        textView.delegate = context.coordinator
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 2, bottom: 8, right: 2)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let parent: TranscriptTextEditor

        init(parent: TranscriptTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }
    }
}

#Preview {
    SessionEndView(
        reviewText: .constant("これは録音終了後に表示されるサンプルの文字起こしです。"),
        onSaveEdits: { _ in },
        onDismiss: {}
    )
}
