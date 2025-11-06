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
    private static let sharedDefaults: UserDefaults = {
        if let groupID = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
           !groupID.isEmpty,
           let defaults = UserDefaults(suiteName: groupID) {
            return defaults
        }
        return .standard
    }()
    static let pendingStartRequestKey = "PendingStartRecordingRequest"

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
    private var currentSessionEntryID: UUID?
    private var sessionAccumulatedTranscript: String = ""
    private var currentTranscriptDraft: String = ""
    private var lastAudioActivity: Date = Date()
    private let silenceDuration: TimeInterval = 2.0
    private let silenceLevelThreshold: Float = 0.05

    private enum SaveTrigger {
        case recognitionFinal
        case silence
        case stop
        case cleanup
        case deinitCleanup
        case sessionStart
    }

    init() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        historyURL = documentsURL.appendingPathComponent("transcripts.json")

        loadHistory()
        configureRecognizer()
        lastAudioActivity = Date()
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
        clearPendingStartRequestFlag()
        finalizeCurrentSessionIfNeeded(reason: .sessionStart)
        resetCurrentSessionState()

        guard permissionGranted else { return }
        guard let recognizer = recognizer, recognizer.isAvailable else {
            print("音声認識を利用できません")
            return
        }

        transcript = ""
        sessionEnded = false
        lastAudioActivity = Date()

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
                    self.handleRecognitionResult(result)
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
            finalizeCurrentSessionIfNeeded(reason: .stop)
            resetCurrentSessionState()
            return
        }

        isRecording = false

        finalizeCurrentSessionIfNeeded(reason: .stop)
        resetCurrentSessionState()
        teardownRecordingResources(deleteTemporaryFile: false)

        audioLevel = 0.0
    }

    @MainActor func cleanup() {
        guard isRecording || hasActiveTap || task != nil else {
            finalizeCurrentSessionIfNeeded(reason: .cleanup)
            resetCurrentSessionState()
            teardownRecordingResources(deleteTemporaryFile: true)
            audioLevel = 0.0
            return
        }

        isRecording = false

        finalizeCurrentSessionIfNeeded(reason: .cleanup)
        resetCurrentSessionState()
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
            rewriteHistoryFile()
        }
    }

    func markAsRead(_ entry: TranscriptEntry) {
        guard let index = history.firstIndex(where: { $0.id == entry.id }) else { return }
        if !history[index].isRead {
            history[index].isRead = true
            rewriteHistoryFile()
        }
    }

    func toggleReadState(for entry: TranscriptEntry) {
        guard let index = history.firstIndex(where: { $0.id == entry.id }) else { return }
        history[index].isRead.toggle()
        rewriteHistoryFile()
    }

    @discardableResult
    func consumePendingStartRequest() -> Bool {
        Self.consumePendingStartRequestFlag()
    }

    func schedulePendingStartRequest() {
        Self.schedulePendingStartRequestFlag()
    }

    private func clearPendingStartRequestFlag() {
        Self.clearPendingStartRequestFlag()
    }

    @discardableResult
    private static func consumePendingStartRequestFlag() -> Bool {
        guard sharedDefaults.bool(forKey: pendingStartRequestKey) else { return false }
        sharedDefaults.set(false, forKey: pendingStartRequestKey)
        return true
    }

    private static func schedulePendingStartRequestFlag() {
        sharedDefaults.set(true, forKey: pendingStartRequestKey)
    }

    private static func clearPendingStartRequestFlag() {
        if sharedDefaults.bool(forKey: pendingStartRequestKey) {
            sharedDefaults.set(false, forKey: pendingStartRequestKey)
        }
    }

    static func scheduleGlobalStartRequest() {
        schedulePendingStartRequestFlag()
    }

    @discardableResult
    static func consumeGlobalStartRequest() -> Bool {
        consumePendingStartRequestFlag()
    }

    func deleteEntries(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        rewriteHistoryFile()
    }

    func deleteEntry(_ entry: TranscriptEntry) {
        guard let index = history.firstIndex(where: { $0.id == entry.id }) else { return }
        history.remove(at: index)
        rewriteHistoryFile()
    }

    func entry(with id: UUID) -> TranscriptEntry? {
        history.first(where: { $0.id == id })
    }

    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult) {
        let recognizedText = result.bestTranscription.formattedString
        transcript = recognizedText

        updateCurrentTranscriptDraft(with: recognizedText)

        if result.isFinal {
            recordCurrentTranscriptIfNeeded(reason: .recognitionFinal)
        }

        if containsFinishKeyword(recognizedText) {
            stopRecording()
            sessionEnded = true
        }
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

    private func appendHistoryEntryToDisk(_ entry: TranscriptEntry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            let entryData = try encoder.encode(entry)
            let entryString = String(data: entryData, encoding: .utf8) ?? ""
            let fileManager = FileManager.default

            var isEmptyFile = true
            if fileManager.fileExists(atPath: historyURL.path),
               let attributes = try? fileManager.attributesOfItem(atPath: historyURL.path),
               let fileSize = attributes[.size] as? NSNumber {
                isEmptyFile = fileSize.intValue == 0
            }

            if !fileManager.fileExists(atPath: historyURL.path) || isEmptyFile {
                let wrapped = "[\n\(entryString)\n]"
                try Data(wrapped.utf8).write(to: historyURL, options: [.atomic])
                return
            }

            guard let handle = try? FileHandle(forUpdating: historyURL) else {
                rewriteHistoryFile(using: encoder)
                return
            }
            defer { try? handle.close() }

            let newlineClosing = Data("\n]".utf8)
            let plainClosing = Data("]".utf8)

            let fileSize = handle.seekToEndOfFile()
            var closingLength: UInt64 = 0

            if fileSize >= UInt64(newlineClosing.count) {
                handle.seek(toFileOffset: fileSize - UInt64(newlineClosing.count))
                if handle.readData(ofLength: newlineClosing.count) == newlineClosing {
                    closingLength = UInt64(newlineClosing.count)
                }
            }

            if closingLength == 0, fileSize >= 1 {
                handle.seek(toFileOffset: fileSize - 1)
                if handle.readData(ofLength: 1) == plainClosing {
                    closingLength = 1
                }
            }

            guard closingLength > 0 else {
                rewriteHistoryFile(using: encoder)
                return
            }

            let tailOffset = fileSize - closingLength
            handle.truncateFile(atOffset: tailOffset)
            handle.seekToEndOfFile()

            if history.count > 1 {
                handle.write(Data(",\n".utf8))
            } else {
                handle.write(Data("\n".utf8))
            }

            handle.write(entryData)
            handle.write(newlineClosing)
        } catch {
            print("履歴の保存に失敗しました: \(error)")
        }
    }

    private func updateLastHistoryEntryOnDisk(_ entry: TranscriptEntry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            let entryData = try encoder.encode(entry)
            let entryString = String(data: entryData, encoding: .utf8) ?? ""
            let fileData = try Data(contentsOf: historyURL)
            guard var fileText = String(data: fileData, encoding: .utf8) else {
                rewriteHistoryFile(using: encoder)
                return
            }

            guard let closingRange = fileText.range(of: "\n]", options: .backwards) ?? fileText.range(of: "]", options: .backwards) else {
                rewriteHistoryFile(using: encoder)
                return
            }

            let prefixText = fileText[..<closingRange.lowerBound]
            let lastEntryStart: String.Index
            let hasMultipleEntries: Bool

            if let separatorRange = prefixText.range(of: ",\n", options: .backwards) {
                lastEntryStart = separatorRange.lowerBound
                hasMultipleEntries = true
            } else if let arrayStart = fileText.range(of: "[\n") {
                lastEntryStart = arrayStart.upperBound
                hasMultipleEntries = false
            } else if let arrayStart = fileText.firstIndex(of: "[") {
                lastEntryStart = fileText.index(after: arrayStart)
                hasMultipleEntries = false
            } else {
                rewriteHistoryFile(using: encoder)
                return
            }

            let prefixToKeep = fileText[..<lastEntryStart]
            let offset = prefixToKeep.utf8.count

            guard let handle = try? FileHandle(forUpdating: historyURL) else {
                rewriteHistoryFile(using: encoder)
                return
            }
            defer { try? handle.close() }

            handle.truncateFile(atOffset: UInt64(offset))
            handle.seekToEndOfFile()

            if hasMultipleEntries {
                handle.write(Data(",\n".utf8))
            } else if !prefixToKeep.hasSuffix("\n") {
                handle.write(Data("\n".utf8))
            }

            handle.write(Data(entryString.utf8))
            handle.write(Data("\n]".utf8))
        } catch {
            print("履歴の保存に失敗しました: \(error)")
        }
    }

    private func rewriteHistoryFile(using encoder: JSONEncoder? = nil) {
        let encoder = encoder ?? {
            let jsonEncoder = JSONEncoder()
            jsonEncoder.dateEncodingStrategy = .iso8601
            return jsonEncoder
        }()

        do {
            let data = try encoder.encode(history)
            try data.write(to: historyURL, options: [.atomic])
        } catch {
            print("履歴の保存に失敗しました: \(error)")
        }
    }

    private func updateCurrentTranscriptDraft(with recognizedText: String) {
        let trimmed = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            currentTranscriptDraft = ""
            return
        }

        if !sessionAccumulatedTranscript.isEmpty,
           trimmed.hasPrefix(sessionAccumulatedTranscript) {
            let startIndex = trimmed.index(trimmed.startIndex, offsetBy: sessionAccumulatedTranscript.count)
            let remainder = trimmed[startIndex...]
            currentTranscriptDraft = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            currentTranscriptDraft = trimmed
            if currentSessionEntryID != nil {
                sessionAccumulatedTranscript = ""
            }
        }
    }

    // 保存タイミング: 認識確定時 or 無音2秒 or stopRecording/cleanup/deinit 時
    private func recordCurrentTranscriptIfNeeded(reason: SaveTrigger) {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        var trimmedDraft = currentTranscriptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDraft.isEmpty,
           !trimmedTranscript.isEmpty,
           trimmedTranscript != sessionAccumulatedTranscript {
            trimmedDraft = trimmedTranscript
            sessionAccumulatedTranscript = ""
        }

        guard !trimmedDraft.isEmpty else { return }

        let finalText: String
        if sessionAccumulatedTranscript.isEmpty {
            finalText = trimmedDraft
        } else {
            let needsSeparator = !sessionAccumulatedTranscript.hasSuffix("\n") && !sessionAccumulatedTranscript.isEmpty
            finalText = sessionAccumulatedTranscript + (needsSeparator ? "\n" : "") + trimmedDraft
        }

        if let entryID = currentSessionEntryID,
           let index = history.firstIndex(where: { $0.id == entryID }) {
            var entry = history.remove(at: index)
            entry.text = finalText
            entry.isRead = false
            history.insert(entry, at: 0)
            sessionAccumulatedTranscript = finalText
            currentTranscriptDraft = ""
            updateLastHistoryEntryOnDisk(entry)
        } else {
            let entry = TranscriptEntry(
                id: UUID(),
                createdAt: Date(),
                text: finalText,
                isRead: false
            )
            history.insert(entry, at: 0)
            currentSessionEntryID = entry.id
            sessionAccumulatedTranscript = finalText
            currentTranscriptDraft = ""
            appendHistoryEntryToDisk(entry)
        }

        lastAudioActivity = Date()
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
            if normalizedLevel > self.silenceLevelThreshold {
                self.lastAudioActivity = Date()
            }
        }
    }

    private func startLevelMonitoring() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.isRecording {
                self.levelTimer?.invalidate()
                self.levelTimer = nil
                return
            }

            if Date().timeIntervalSince(self.lastAudioActivity) >= self.silenceDuration {
                self.updateCurrentTranscriptDraft(with: self.transcript)
                self.recordCurrentTranscriptIfNeeded(reason: .silence)
                self.lastAudioActivity = Date()
            }
        }
    }

    private func resetCurrentSessionState() {
        currentSessionEntryID = nil
        sessionAccumulatedTranscript = ""
        currentTranscriptDraft = ""
    }

    private func finalizeCurrentSessionIfNeeded(reason: SaveTrigger) {
        updateCurrentTranscriptDraft(with: transcript)
        recordCurrentTranscriptIfNeeded(reason: reason)
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
            finalizeCurrentSessionIfNeeded(reason: .deinitCleanup)
            teardownRecordingResources(deleteTemporaryFile: true)
        }
    }
}
