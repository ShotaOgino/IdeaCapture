//
//  IdeaCaptureTests.swift
//  IdeaCaptureTests
//
//  Created by Shota on 2025/11/06.
//

import Foundation
import Testing
@testable import IdeaCapture

@MainActor
struct IdeaCaptureTests {

    @Test
    func finalResultDoesNotCompleteWithoutStopRequest() throws {
        let historyURL = try makeTempHistoryURL()
        defer { cleanupTempHistory(at: historyURL) }

        let viewModel = RecorderViewModel(historyURL: historyURL)
        viewModel.isRecording = true

        viewModel.processRecognitionUpdate(transcript: "最初のメモ", isFinal: true, shouldFinishSession: false)

        #expect(viewModel.history.first?.text == "最初のメモ")
        #expect(viewModel._testLastCommittedEntryID != nil)
        #expect(viewModel.isRecording)
    }

    @Test
    func finalResultCompletesAfterStopRequest() throws {
        let historyURL = try makeTempHistoryURL()
        defer { cleanupTempHistory(at: historyURL) }

        let viewModel = RecorderViewModel(historyURL: historyURL)
        viewModel.isRecording = true

        viewModel.processRecognitionUpdate(transcript: "初回のメモ", isFinal: true, shouldFinishSession: false)
        #expect(viewModel.history.count == 1)

        viewModel._testSetAwaitingFinalResult(true)
        viewModel.processRecognitionUpdate(transcript: "最終メモ", isFinal: true, shouldFinishSession: false)

        #expect(viewModel.history.first?.text == "最終メモ")
        #expect(viewModel.history.count == 2)
        #expect(viewModel._testLastCommittedEntryID != nil)
        #expect(viewModel.isRecording == false)
    }

    private func makeTempHistoryURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("transcripts.json")
    }

    private func cleanupTempHistory(at url: URL) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: directory)
    }
}
