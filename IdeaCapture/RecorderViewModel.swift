import SwiftUI
import AVFoundation
import Speech

@MainActor
final class RecorderViewModel: ObservableObject {
    @Published var transcript: String = ""
    @Published var isRecording = false
    @Published var sessionEnded = false
    @Published var audioLevel: Float = 0.0
    @Published var permissionGranted = false

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var audioFile: AVAudioFile?
    private var audioFileURL: URL?
    private var levelTimer: Timer?
    private var hasActiveTap = false

    init() {
        // Initialize recognizer with device locale
        recognizer = SFSpeechRecognizer(locale: Locale.current)

        // Enable on-device recognition if available
        if let recognizer = recognizer, recognizer.supportsOnDeviceRecognition {
            print("On-device recognition is available")
        }
    }

    func requestPermissions() async {
        // Request microphone permission
        let micStatus = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }

        // Request speech recognition permission
        let speechStatus = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }

        permissionGranted = micStatus && speechStatus
    }

    func startRecording() {
        guard permissionGranted else { return }
        guard let recognizer = recognizer, recognizer.isAvailable else {
            print("Speech recognizer not available")
            return
        }

        // Reset state
        transcript = ""
        sessionEnded = false

        // Configure audio session
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("Failed to set up audio session: \(error)")
            return
        }

        // Create recognition request
        request = SFSpeechAudioBufferRecognitionRequest()
        guard let request = request else { return }

        // Enable on-device recognition
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        // Set up audio file for temporary storage
        setupAudioFile()

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Install tap on audio input
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            request.append(buffer)

            // Write to temporary audio file
            try? self?.audioFile?.write(from: buffer)

            // Update audio level for visualization
            self?.updateAudioLevel(buffer: buffer)
        }
        hasActiveTap = true

        // Start audio engine
        audioEngine.prepare()
        do {
            try audioEngine.start()
            isRecording = true
        } catch {
            print("Audio engine failed to start: \(error)")
            teardownRecordingResources(deleteTemporaryFile: true)
            return
        }

        // Start recognition task
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                Task { @MainActor in
                    self.transcript = result.bestTranscription.formattedString

                    // Check for finish keyword
                    if self.containsFinishKeyword(self.transcript) {
                        self.stopRecording()
                        self.sessionEnded = true
                    }
                }
            }

            if error != nil {
                Task { @MainActor in
                    self.stopRecording()
                }
            }
        }

        // Start audio level monitoring
        startLevelMonitoring()
    }

    func stopRecording() {
        guard isRecording || hasActiveTap || task != nil else { return }

        isRecording = false

        teardownRecordingResources(deleteTemporaryFile: false)

        audioLevel = 0.0
    }

    @MainActor func cleanup() {
        guard isRecording || hasActiveTap || task != nil else {
            teardownRecordingResources(deleteTemporaryFile: true)
            audioLevel = 0.0
            return
        }

        isRecording = false

        teardownRecordingResources(deleteTemporaryFile: true)

        audioLevel = 0.0
    }

    private func containsFinishKeyword(_ text: String) -> Bool {
        let lowercased = text.lowercased()

        // Check for various finish keywords in different languages
        let finishKeywords = [
            "finish", "finished",
            "終わり", "おわり", "終了",
            "terminer", "fin",
            "끝", "종료"
        ]

        return finishKeywords.contains { lowercased.contains($0) }
    }

    private func setupAudioFile() {
        let documentsPath = FileManager.default.temporaryDirectory
        audioFileURL = documentsPath.appendingPathComponent("temp_recording_\(Date().timeIntervalSince1970).caf")

        guard let url = audioFileURL else { return }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            audioFile = try AVAudioFile(forWriting: url, settings: settings)
        } catch {
            print("Failed to create audio file: \(error)")
        }
    }

    private func updateAudioLevel(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let channelDataValue = channelData.pointee
        let channelDataArray = stride(from: 0, to: Int(buffer.frameLength), by: buffer.stride).map { channelDataValue[$0] }

        let rms = sqrt(channelDataArray.map { $0 * $0 }.reduce(0, +) / Float(buffer.frameLength))
        let avgPower = 20 * log10(rms)
        let normalizedLevel = max(0, min(1, (avgPower + 50) / 50)) // Normalize to 0-1

        Task { @MainActor in
            self.audioLevel = normalizedLevel
        }
    }

    private func startLevelMonitoring() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            // Audio level is updated in updateAudioLevel
        }
    }

    @MainActor private func teardownRecordingResources(deleteTemporaryFile: Bool) {
        if audioEngine.isRunning {
            audioEngine.stop()
        }

        if hasActiveTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasActiveTap = false
        }

        task?.cancel()
        task = nil

        request?.endAudio()
        request = nil

        levelTimer?.invalidate()
        levelTimer = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        if deleteTemporaryFile {
            if let url = audioFileURL {
                try? FileManager.default.removeItem(at: url)
            }
            audioFileURL = nil
        }

        audioFile = nil
    }

    deinit {
        MainActor.assumeIsolated { [self] in
            teardownRecordingResources(deleteTemporaryFile: true)
        }
    }
}
