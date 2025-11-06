import SwiftUI
import AVFoundation
import Speech

struct TranscriptEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let createdAt: Date
    var text: String
    var isRead: Bool

    var previewText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "（空の文字起こし）" : trimmed
    }
}

@MainActor
final class RecorderViewModel: ObservableObject {
    @Published var transcript: String = ""
    @Published var isRecording = false
    @Published var sessionEnded = false
    @Published var audioLevel: Float = 0.0
    @Published var permissionGranted = false
    @Published private(set) var history: [TranscriptEntry] = []

    var unreadCount: Int {
        history.lazy.filter { !$0.isRead }.count
    }

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var audioFile: AVAudioFile?
    private var audioFileURL: URL?
    private var levelTimer: Timer?
    private var hasActiveTap = false

    private let historyURL: URL
    private var hasSavedTranscriptThisSession = false

    init() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        historyURL = documentsURL.appendingPathComponent("transcripts.json")

        loadHistory()
        configureRecognizer()
    }

    func requestPermissions() async {
        let micStatus = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }

        let speechStatus = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }

        permissionGranted = micStatus && speechStatus
    }

    func startRecording() {
        recordCurrentTranscriptIfNeeded()

        guard permissionGranted else { return }
        guard let recognizer = recognizer, recognizer.isAvailable else {
            print("音声認識を利用できません")
            return
        }

        transcript = ""
        sessionEnded = false
        hasSavedTranscriptThisSession = false

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("オーディオセッションの設定に失敗しました: \(error)")
            return
        }

        request = SFSpeechAudioBufferRecognitionRequest()
        guard let request = request else { return }

        request.shouldReportPartialResults = true

        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        setupAudioFile()

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            request.append(buffer)
            try? self?.audioFile?.write(from: buffer)
            self?.updateAudioLevel(buffer: buffer)
        }
        hasActiveTap = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isRecording = true
        } catch {
            print("オーディオエンジンの起動に失敗しました: \(error)")
            teardownRecordingResources(deleteTemporaryFile: true)
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                Task { @MainActor in
                    self.transcript = result.bestTranscription.formattedString

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

        startLevelMonitoring()
    }

    func stopRecording() {
        guard isRecording || hasActiveTap || task != nil else {
            recordCurrentTranscriptIfNeeded()
            return
        }

        isRecording = false

        recordCurrentTranscriptIfNeeded()

        teardownRecordingResources(deleteTemporaryFile: false)

        audioLevel = 0.0
    }

    @MainActor func cleanup() {
        guard isRecording || hasActiveTap || task != nil else {
            recordCurrentTranscriptIfNeeded()
            teardownRecordingResources(deleteTemporaryFile: true)
            audioLevel = 0.0
            return
        }

        isRecording = false

        recordCurrentTranscriptIfNeeded()
        teardownRecordingResources(deleteTemporaryFile: true)

        audioLevel = 0.0
    }

    func markAllAsRead() {
        var updated = false
        for index in history.indices where !history[index].isRead {
            history[index].isRead = true
            updated = true
        }
        if updated {
            persistHistory()
        }
    }

    func markAsRead(_ entry: TranscriptEntry) {
        guard let index = history.firstIndex(where: { $0.id == entry.id }) else { return }
        if !history[index].isRead {
            history[index].isRead = true
            persistHistory()
        }
    }

    func toggleReadState(for entry: TranscriptEntry) {
        guard let index = history.firstIndex(where: { $0.id == entry.id }) else { return }
        history[index].isRead.toggle()
        persistHistory()
    }

    func deleteEntries(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        persistHistory()
    }

    func deleteEntry(_ entry: TranscriptEntry) {
        guard let index = history.firstIndex(where: { $0.id == entry.id }) else { return }
        history.remove(at: index)
        persistHistory()
    }

    func entry(with id: UUID) -> TranscriptEntry? {
        history.first(where: { $0.id == id })
    }

    private func configureRecognizer() {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
        recognizer?.defaultTaskHint = .dictation

        if let recognizer = recognizer {
            if recognizer.supportsOnDeviceRecognition {
                print("オンデバイス音声認識を利用できます")
            }
        } else {
            print("日本語の音声認識がサポートされていません")
        }
    }

    private func loadHistory() {
        do {
            let data = try Data(contentsOf: historyURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([TranscriptEntry].self, from: data)
            history = decoded.sorted(by: { $0.createdAt > $1.createdAt })
        } catch {
            history = []
        }
    }

    private func persistHistory() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(history)
            try data.write(to: historyURL, options: [.atomic])
        } catch {
            print("履歴の保存に失敗しました: \(error)")
        }
    }

    private func recordCurrentTranscriptIfNeeded() {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !hasSavedTranscriptThisSession else { return }

        let entry = TranscriptEntry(
            id: UUID(),
            createdAt: Date(),
            text: trimmed,
            isRead: false
        )

        history.insert(entry, at: 0)
        persistHistory()
        hasSavedTranscriptThisSession = true
    }

    private func containsFinishKeyword(_ text: String) -> Bool {
        let lowercased = text.lowercased()

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
            print("一時オーディオファイルの作成に失敗しました: \(error)")
        }
    }

    private func updateAudioLevel(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let channelDataValue = channelData.pointee
        let channelDataArray = stride(from: 0, to: Int(buffer.frameLength), by: buffer.stride).map { channelDataValue[$0] }

        let rms = sqrt(channelDataArray.map { $0 * $0 }.reduce(0, +) / Float(buffer.frameLength))
        let avgPower = 20 * log10(max(rms, 0.000_000_1))
        let normalizedLevel = max(0, min(1, (avgPower + 50) / 50))

        Task { @MainActor in
            self.audioLevel = normalizedLevel
        }
    }

    private func startLevelMonitoring() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            // Audio level is updated in updateAudioLevel
            guard let self else { return }
            if !self.isRecording {
                self.levelTimer?.invalidate()
                self.levelTimer = nil
            }
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
        Task { @MainActor [self] in
            recordCurrentTranscriptIfNeeded()
            teardownRecordingResources(deleteTemporaryFile: true)
        }
    }
}
