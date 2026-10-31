import Foundation
import Speech
import AVFoundation

/// The microphone tap only sees this locked request slot, not UI state.
final class SpeechRequestSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    func set(_ value: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); request = value; lock.unlock() }
    func append(_ buffer: AVAudioPCMBuffer) { lock.lock(); request?.append(buffer); lock.unlock() }
}

@MainActor
final class LiveSpeechPreview {
    let slot = SpeechRequestSlot()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var generation = UUID()
    private var restart: Task<Void, Never>?
    private var active = false
    private var failures = 0
    private(set) var latestText = ""
    private var latestTextAt = Date.distantPast
    var recentText: String? { Date().timeIntervalSince(latestTextAt) < 3 && !latestText.isEmpty ? latestText : nil }
    var onText: ((String) -> Void)?
    var supported: Bool { recognizer?.supportsOnDeviceRecognition == true }
    var permitted: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized && supported }

    func requestPermission() async -> Bool {
        guard supported else { return false }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            return status == .authorized
        }
        return permitted
    }
    func start() { stop(); latestText = ""; latestTextAt = .distantPast; guard permitted else { return }; active = true; failures = 0; begin() }
    private func begin() {
        guard active, permitted, let recognizer, recognizer.isAvailable else { return }
        let id = UUID(); generation = id
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = ["Jarvis", "Aryan here to start working", "Instagram", "Claude", "Outlook", "Nifty", "Sensex", "Bitcoin"]
        self.request = request; slot.set(request)
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.active, self.generation == id else { return }
                if let result {
                    self.failures = 0
                    let text = result.bestTranscription.formattedString
                    self.latestTextAt = Date()
                    if self.latestText != text {
                        self.latestText = text
                        self.onText?(text)
                    }
                }
                if result?.isFinal == true || error != nil {
                    self.generation = UUID(); self.slot.set(nil); self.request?.endAudio(); self.task?.cancel()
                    self.task = nil; self.request = nil
                    if error != nil { self.failures += 1 }
                    guard self.failures < 3 else { return }
                    self.restart = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 750_000_000)
                        guard !Task.isCancelled else { return }; self?.begin()
                    }
                }
            }
        }
    }
    func stop() {
        active = false; generation = UUID(); restart?.cancel(); restart = nil
        slot.set(nil); request?.endAudio(); task?.cancel(); task = nil; request = nil
    }
}
