import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = RecorderViewModel()
    @State private var showPermissionAlert = false

    var body: some View {
        ZStack {
            // Background
            Color.black.ignoresSafeArea()

            if viewModel.sessionEnded {
                SessionEndView(
                    transcript: viewModel.transcript,
                    onDismiss: {
                        viewModel.sessionEnded = false
                        viewModel.transcript = ""
                    }
                )
            } else {
                VStack(spacing: 40) {
                    Spacer()

                    // Waveform visualization
                    WaveformView(
                        audioLevel: viewModel.audioLevel,
                        isRecording: viewModel.isRecording
                    )
                    .frame(height: 200)
                    .padding(.horizontal, 30)

                    // Microphone indicator
                    Button {
                        if viewModel.isRecording {
                            viewModel.stopRecording()
                        } else if viewModel.permissionGranted {
                            viewModel.startRecording()
                        } else {
                            showPermissionAlert = true
                        }
                    } label: {
                        ZStack {
                            if viewModel.isRecording {
                                Circle()
                                    .fill(Color.red.opacity(0.3))
                                    .frame(width: 120, height: 120)
                                    .scaleEffect(viewModel.audioLevel > 0.1 ? 1.2 : 1.0)
                                    .animation(.easeInOut(duration: 0.2), value: viewModel.audioLevel)
                            }

                            Circle()
                                .fill(viewModel.isRecording ? Color.red : Color.gray)
                                .frame(width: 80, height: 80)

                            Image(systemName: "mic.fill")
                                .font(.system(size: 35))
                                .foregroundColor(.white)
                        }
                    }
                    .buttonStyle(.plain)

                    // Status text
                    Text(viewModel.isRecording ? "録音中..." : "タップして録音開始")
                        .font(.system(.title2, design: .rounded))
                        .fontWeight(.semibold)
                        .foregroundColor(.white.opacity(0.9))

                    // Live transcription
                    if viewModel.isRecording && !viewModel.transcript.isEmpty {
                        ScrollView {
                            Text(viewModel.transcript)
                                .font(.system(.body, design: .rounded))
                                .foregroundColor(.white.opacity(0.7))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 30)
                                .frame(maxWidth: .infinity)
                        }
                        .frame(maxHeight: 150)
                    }

                    Spacer()

                    // Control buttons
                    HStack(spacing: 40) {
                        if viewModel.isRecording {
                            Button(action: {
                                viewModel.stopRecording()
                            }) {
                                VStack {
                                    Image(systemName: "stop.fill")
                                        .font(.system(size: 30))
                                    Text("停止")
                                        .font(.system(.caption, design: .rounded))
                                }
                                .foregroundColor(.white)
                            }
                        } else {
                            Button(action: {
                                if viewModel.permissionGranted {
                                    viewModel.startRecording()
                                } else {
                                    showPermissionAlert = true
                                }
                            }) {
                                VStack {
                                    Image(systemName: "record.circle")
                                        .font(.system(size: 30))
                                    Text("録音")
                                        .font(.system(.caption, design: .rounded))
                                }
                                .foregroundColor(.red)
                            }
                        }
                    }
                    .padding(.bottom, 50)
                }
            }
        }
        .task {
            await viewModel.requestPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .startRecording)) { _ in
            if viewModel.permissionGranted && !viewModel.isRecording {
                viewModel.startRecording()
            }
        }
        .alert("権限が必要です", isPresented: $showPermissionAlert) {
            Button("閉じる") { }
            Button("設定を開く") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } message: {
            Text("IdeaCapture がアイデアを録音・文字起こしするにはマイクと音声認識へのアクセスが必要です。設定でこれらの権限を有効にしてください。")
        }
    }
}

#Preview {
    ContentView()
}
