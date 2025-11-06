import SwiftUI

struct SessionEndView: View {
    let transcript: String
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 30) {
                Spacer()

                // Checkmark icon
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.2))
                        .frame(width: 100, height: 100)

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.green)
                }

                // Title
                Text("録音を終了しました")
                    .font(.system(.title, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                // Transcript preview
                if !transcript.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("最後の文字起こし")
                            .font(.system(.caption, design: .rounded))
                            .foregroundColor(.white.opacity(0.6))

                        ScrollView {
                            Text(transcript)
                                .font(.system(.body, design: .rounded))
                                .foregroundColor(.white.opacity(0.8))
                                .padding()
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.white.opacity(0.1))
                                )
                        }
                        .frame(maxHeight: 200)
                    }
                    .padding(.horizontal, 30)
                }

                Text("アプリを閉じるとこの文字起こしは削除されます。")
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                Spacer()

                // Done button
                Button(action: onDismiss) {
                    Text("完了")
                        .font(.system(.headline, design: .rounded))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.blue)
                        )
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 50)
            }
        }
    }
}

#Preview {
    SessionEndView(
        transcript: "これは録音終了後に表示されるサンプルの文字起こしです。ユーザーが「終了」と話したことで録音が停止しました。",
        onDismiss: {}
    )
}
