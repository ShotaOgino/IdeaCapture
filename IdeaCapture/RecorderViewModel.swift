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
    @Published var reviewTranscript: String = ""
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
    private let transcriptsDirectoryURL: URL
    private var lastCommittedEntryID: UUID?
    private var awaitingFinalResult = false
    private var pendingTeardownDeleteTemporaryFile = false
    private var hasUncommittedTranscriptChanges = false
    private var accumulatedTranscript: String = ""
    private var committedText: String = ""           // 直前までのFinal確定分
    private var currentPartialText: String = ""      // 現在の部分結果（未確定）
    private var sessionStartDate: Date?
    private var hasSavedSessionToFile: Bool = false
    @Published private(set) var lastSavedTranscriptFileURL: URL?

    init(historyURL: URL? = nil) {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        self.historyURL = historyURL ?? documentsURL.appendingPathComponent("transcripts.json")
        self.transcriptsDirectoryURL = documentsURL.appendingPathComponent("Transcripts", isDirectory: true)

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
        clearPendingStartRequestFlag()
        guard task == nil else {
            print("前回の音声認識がまだ終了していません")
            return
        }

        prepareForNewSession()
        awaitingFinalResult = false
        pendingTeardownDeleteTemporaryFile = false
        sessionStartDate = Date()
        hasSavedSessionToFile = false

        guard permissionGranted else { return }
        guard let recognizer = recognizer, recognizer.isAvailable else {
            print("音声認識を利用できません")
            return
        }

        transcript = ""
        sessionEnded = false

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
            } else if error == nil {
                Task { @MainActor in
                    self.handleRecognitionCompletionIfNeeded()
                }
            }

            if let error = error {
                Task { @MainActor in
                    self.handleRecognitionError(error)
                }
            }
        }

        startLevelMonitoring()
    }

    func stopRecording() {
        guard isRecording || hasActiveTap || task != nil else {
            return
        }

        isRecording = false
        requestFinalTranscription(deleteTemporaryFile: false)
    }

    @MainActor func cleanup() {
        guard isRecording || hasActiveTap || task != nil else {
            teardownRecordingResources(deleteTemporaryFile: true)
            audioLevel = 0.0
            return
        }

        isRecording = false
        requestFinalTranscription(deleteTemporaryFile: true)
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

    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult) {
        let updatedTranscript = result.bestTranscription.formattedString
        let shouldFinishSession = containsFinishKeyword(updatedTranscript) || containsFinishKeyword(in: result.bestTranscription.segments)
        processRecognitionUpdate(transcript: updatedTranscript, isFinal: result.isFinal, shouldFinishSession: shouldFinishSession)
    }

    func processRecognitionUpdate(transcript newTranscript: String, isFinal: Bool, shouldFinishSession: Bool) {
        let textChanged = transcript != newTranscript
        transcript = newTranscript

        if textChanged {
            hasUncommittedTranscriptChanges = true
            let trimmed = newTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

            // 以前までの全文と新しい結果をマージ
            let previousFull = accumulatedTranscript
            accumulatedTranscript = mergeTranscript(previousFull, trimmed)
        }

        if shouldFinishSession {
            sessionEnded = true
            if !awaitingFinalResult {
                stopRecording()
            }
        }

        if isFinal {
            // 現時点の全文を確定し、部分結果をクリア
            committedText = accumulatedTranscript
            currentPartialText = ""

            // 次の認識のためにUI用テキストをリセット
            transcript = ""
            hasUncommittedTranscriptChanges = false

            if awaitingFinalResult {
                commitAccumulatedTranscript()
                completeRecognitionSession()
            }
        }
    }

    // 末尾/先頭の重なりを返す（大文字小文字区別なし、最大64文字）
    private func longestOverlapSuffixPrefix(_ a: String, _ b: String) -> Int {
        let aNorm = a
        let bNorm = b
        let maxLen = min(64, min(aNorm.count, bNorm.count))
        if maxLen == 0 { return 0 }
        for len in stride(from: maxLen, through: 1, by: -1) {
            let aSuffix = String(aNorm.suffix(len))
            let bPrefix = String(bNorm.prefix(len))
            if aSuffix.caseInsensitiveCompare(bPrefix) == .orderedSame { return len }
        }
        return 0
    }

    private func longestCommonPrefixLen(_ a: String, _ b: String) -> Int {
        let aArr = Array(a)
        let bArr = Array(b)
        let maxLen = min(aArr.count, bArr.count)
        var i = 0
        while i < maxLen && aArr[i] == bArr[i] { i += 1 }
        return i
    }

    // 以前までの全文 prev と新しい全文/セグメント new のマージ
    // - new が prev を拡張: new を採用
    // - prev が new を包含: 何もしない（前半が消えない）
    // - 末尾/先頭の重なりあり: 重複を除いて結合
    // - それ以外: 新しいセグメントとしてスペースで連結
    // - 末尾の小規模な訂正は LCP 以降を置き換え
    private func mergeTranscript(_ prev: String, _ new: String) -> String {
        let p = prev.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = new.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { return n }
        if n.isEmpty { return p }
        if n.hasPrefix(p) { return n }
        if p.hasPrefix(n) { return p }

        let overlap = longestOverlapSuffixPrefix(p, n)
        if overlap > 0 {
            return p + String(n.dropFirst(overlap))
        }

        let lcp = longestCommonPrefixLen(p, n)
        if lcp > 0 {
            let prefix = String(p.prefix(lcp))
            let nTail = String(n.dropFirst(lcp))
            return joinWithSpace(prefix, nTail)
        }

        return joinWithSpace(p, n)
    }

    private func joinWithSpace(_ a: String, _ b: String) -> String {
        let aT = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let bT = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if aT.isEmpty { return bT }
        if bT.isEmpty { return aT }
        if aT.hasSuffix(" ") || bT.hasPrefix(" ") { return aT + bT }
        return aT + " " + bT
    }

    private func requestFinalTranscription(deleteTemporaryFile: Bool) {
        pendingTeardownDeleteTemporaryFile = pendingTeardownDeleteTemporaryFile || deleteTemporaryFile

        guard task != nil else {
            completeRecognitionSession(forceDeleteFile: deleteTemporaryFile)
            return
        }

        if awaitingFinalResult {
            return
        }

        awaitingFinalResult = true

        if audioEngine.isRunning {
            audioEngine.stop()
        }

        if hasActiveTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasActiveTap = false
        }

        levelTimer?.invalidate()
        levelTimer = nil

        request?.endAudio()
        audioLevel = 0.0
    }

    private func completeRecognitionSession(forceDeleteFile: Bool? = nil) {
        let deleteFile = forceDeleteFile ?? pendingTeardownDeleteTemporaryFile
        pendingTeardownDeleteTemporaryFile = false
        awaitingFinalResult = false
        isRecording = false
        teardownRecordingResources(deleteTemporaryFile: deleteFile)
        audioLevel = 0.0
        hasUncommittedTranscriptChanges = false
    }

    private func handleRecognitionCompletionIfNeeded() {
        guard awaitingFinalResult else { return }
        commitAccumulatedTranscript()
        completeRecognitionSession()
    }

    private func handleRecognitionError(_ error: Error) {
        print("音声認識中にエラーが発生しました: \(error.localizedDescription)")
        isRecording = false
        commitAccumulatedTranscript()
        completeRecognitionSession()
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            let ordered = Array(history.reversed())
            let data = try encoder.encode(ordered)
            try data.write(to: historyURL, options: [.atomic])
        } catch {
            print("履歴の保存に失敗しました: \(error)")
        }
    }

    // 保存タイミング: 音声認識最終結果 / stopRecording / cleanup / deinit 時
    private func commitAccumulatedTranscript() {
        let trimmed = accumulatedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // セッション終了時に1つのテキストファイルへ保存
        persistSessionTranscriptToTextFile(trimmed)

        // 既存のアプリUIのために履歴にも1件保存（必要に応じて維持）
        let entry = TranscriptEntry(
            id: UUID(),
            createdAt: Date(),
            text: trimmed,
            isRead: false
        )
        history.insert(entry, at: 0)

        lastCommittedEntryID = entry.id
        reviewTranscript = trimmed
        persistHistory()
    }

    private func persistSessionTranscriptToTextFile(_ text: String) {
        guard !hasSavedSessionToFile else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // ディレクトリ作成（なければ作成）
        do {
            try FileManager.default.createDirectory(at: transcriptsDirectoryURL, withIntermediateDirectories: true)
        } catch {
            print("テキスト保存用ディレクトリの作成に失敗しました: \(error)")
        }

        // ファイル名: transcript_YYYYMMDD_HHMMSS.txt
        let date = sessionStartDate ?? Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let datePart = formatter.string(from: date)
        let fileURL = transcriptsDirectoryURL.appendingPathComponent("transcript_\(datePart).txt")

        do {
            try trimmed.data(using: .utf8)?.write(to: fileURL, options: [.atomic])
            lastSavedTranscriptFileURL = fileURL
            hasSavedSessionToFile = true
        } catch {
            print("文字起こしファイルの保存に失敗しました: \(error)")
        }
    }

    private let finishKeywords: [String] = [
        "finish", "finished",
        "終わり", "おわり", "終了",
        "terminer", "fin",
        "끝", "종료"
    ]

    private func containsFinishKeyword(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return finishKeywords.contains { lowercased.contains($0) }
    }

    private func containsFinishKeyword(in segments: [SFTranscriptionSegment]) -> Bool {
        guard let last = segments.last else { return false }
        let normalized = last.substring.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return finishKeywords.contains { normalized == $0 || normalized.hasSuffix($0) }
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
            guard let self else { return }
            if !self.isRecording {
                self.levelTimer?.invalidate()
                self.levelTimer = nil
            }
        }
    }

    private func prepareForNewSession() {
        lastCommittedEntryID = nil
        reviewTranscript = ""
        hasUncommittedTranscriptChanges = false
        accumulatedTranscript = ""
        committedText = ""
        currentPartialText = ""
        lastSavedTranscriptFileURL = nil
        sessionStartDate = nil
        hasSavedSessionToFile = false
    }

    func updateLastCommittedEntry(with newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        transcript = trimmed
        reviewTranscript = trimmed
        hasUncommittedTranscriptChanges = false

        if let entryID = lastCommittedEntryID,
           let index = history.firstIndex(where: { $0.id == entryID }) {
            history[index].text = trimmed
            history[index].isRead = false
            if index != 0 {
                let entry = history.remove(at: index)
                history.insert(entry, at: 0)
            }
            lastCommittedEntryID = entryID
        } else if let firstIndex = history.indices.first {
            history[firstIndex].text = trimmed
            history[firstIndex].isRead = false
            lastCommittedEntryID = history[firstIndex].id
        } else {
            let entry = TranscriptEntry(
                id: UUID(),
                createdAt: Date(),
                text: trimmed,
                isRead: false
            )
            history.insert(entry, at: 0)
            lastCommittedEntryID = entry.id
        }

        persistHistory()
    }

    func dismissSessionReview() {
        sessionEnded = false
        transcript = ""
        reviewTranscript = ""
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
            commitAccumulatedTranscript()
            completeRecognitionSession(forceDeleteFile: true)
        }
    }
}

#if DEBUG
extension RecorderViewModel {
    func _testSetAwaitingFinalResult(_ value: Bool) {
        awaitingFinalResult = value
    }

    var _testLastCommittedEntryID: UUID? {
        lastCommittedEntryID
    }
}
#endif
