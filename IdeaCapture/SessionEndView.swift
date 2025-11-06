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
                Text("Recording Ended")
                    .font(.system(.title, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                // Transcript preview
                if !transcript.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Last Transcript:")
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

                Text("This transcript will be deleted when you close the app.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                Spacer()

                // Done button
                Button(action: onDismiss) {
                    Text("Done")
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
        transcript: "This is a sample transcript that will be displayed after the recording session ends. The user said finish to end the recording.",
        onDismiss: {}
    )
}
