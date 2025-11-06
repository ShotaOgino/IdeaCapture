import SwiftUI

struct WaveformView: View {
    let audioLevel: Float
    let isRecording: Bool

    @State private var wavePhase: Double = 0

    private let numberOfBars = 50
    private let barSpacing: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: barSpacing) {
                ForEach(0..<numberOfBars, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            LinearGradient(
                                colors: [.red.opacity(0.6), .red],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(
                            width: (geometry.size.width - CGFloat(numberOfBars - 1) * barSpacing) / CGFloat(numberOfBars),
                            height: barHeight(for: index, in: geometry)
                        )
                        .animation(.easeInOut(duration: 0.1), value: audioLevel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .onAppear {
            if isRecording {
                startAnimation()
            }
        }
        .onChange(of: isRecording) { _, recording in
            if recording {
                startAnimation()
            }
        }
    }

    private func barHeight(for index: Int, in geometry: GeometryProxy) -> CGFloat {
        let maxHeight = geometry.size.height
        let minHeight: CGFloat = 4

        if !isRecording {
            return minHeight
        }

        // Create a wave effect
        let progress = Double(index) / Double(numberOfBars)
        let wave = sin(progress * .pi * 4 + wavePhase) * 0.5 + 0.5

        // Combine wave with audio level
        let combinedLevel = (Double(audioLevel) * 0.7 + wave * 0.3)

        return minHeight + CGFloat(combinedLevel) * (maxHeight - minHeight)
    }

    private func startAnimation() {
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            if isRecording {
                wavePhase += 0.1
            } else {
                timer.invalidate()
            }
        }
    }
}
