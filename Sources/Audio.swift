import AppKit
import AVFoundation
import OSLog

enum AudioLog {
    static let logger = Logger(subsystem: "com.local.jarvis", category: "audio")
    static let diagnosticUntil: TimeInterval = ProcessInfo.processInfo.arguments.contains("--diagnose-audio") ? ProcessInfo.processInfo.systemUptime + 30 : 0
}

@MainActor
final class VoiceOutput: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    let synthesizer = AVSpeechSynthesizer()
    private var greetingPlayer: AVAudioPlayer?
    private var replyPlayer: AVAudioPlayer?
    private var replyFile: URL?
    private var queue: [String] = []
    private var renderTask: Task<Void, Never>?
    private var generation = UUID()
    var onFinished: (() -> Void)?
    override init() {
        super.init()
        synthesizer.delegate = self
        if let url = Bundle.main.url(forResource: "office-greeting", withExtension: "aiff"),
           let player = try? AVAudioPlayer(contentsOf: url) {
            player.delegate = self
            player.prepareToPlay()
            greetingPlayer = player
            AudioLog.logger.notice("Local greeting prepared, duration: \(player.duration)")
        }
    }
    var isSpeaking: Bool { synthesizer.isSpeaking || greetingPlayer?.isPlaying == true || replyPlayer?.isPlaying == true || renderTask != nil }
    func welcome() {
        stop()
        if let player = greetingPlayer {
            player.currentTime = 0
            if player.play() { AudioLog.logger.notice("Local greeting playback started"); return }
        }
        say("Welcome to the office, boss.")
        AudioLog.logger.notice("Greeting using speech synthesis fallback")
    }
    func say(_ text: String) {
        var chunks = SpeechChunks()
        queue.append(contentsOf: chunks.consume(String(text.prefix(9000)), final: true))
        startNext()
    }
    private func startNext() {
        guard !isSpeaking, !queue.isEmpty else { return }
        let text = queue.removeFirst()
        let id = generation
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-reply-\(UUID().uuidString).aiff")
        renderTask = Task { [weak self] in
            var keepFile = false
            defer { if !keepFile { try? FileManager.default.removeItem(at: file) } }
            do {
                try await VoiceRenderer.render(text, to: file)
                try Task.checkCancellation()
                guard let self, self.generation == id else { return }
                let player = try AVAudioPlayer(contentsOf: file)
                player.delegate = self; player.prepareToPlay()
                self.replyPlayer = player; self.replyFile = file; self.renderTask = nil
                if player.play() { keepFile = true; AudioLog.logger.notice("Robotic female reply playback started") }
                else { self.replyPlayer = nil; self.replyFile = nil; self.fallback(text) }
            } catch {
                guard let self, self.generation == id, !Task.isCancelled else { return }
                self.renderTask = nil
                AudioLog.logger.error("Local voice rendering failed; using female speech fallback")
                self.fallback(text)
            }
        }
    }
    private func fallback(_ text: String) {
        let utterance = AVSpeechUtterance(string: String(text.prefix(2000)))
        utterance.voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.name == "Samantha" }) ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.55; utterance.pitchMultiplier = 1.08
        synthesizer.speak(utterance)
    }
    func stop() {
        generation = UUID(); renderTask?.cancel(); renderTask = nil
        queue.removeAll()
        greetingPlayer?.stop()
        replyPlayer?.stop(); replyPlayer = nil
        if let replyFile { try? FileManager.default.removeItem(at: replyFile) }; replyFile = nil
        synthesizer.stopSpeaking(at: .immediate)
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        AudioLog.logger.notice("Local voice playback finished successfully: \(flag)")
        Task { @MainActor in
            if player === self.replyPlayer {
                self.replyPlayer = nil
                if let file = self.replyFile { try? FileManager.default.removeItem(at: file) }; self.replyFile = nil
            }
            self.finished()
        }
    }
    private func finished() { startNext(); if !isSpeaking { onFinished?() } }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }
}

final class MonitorAudioState: @unchecked Sendable {
    private var detector = ClapDetector()
    private var speech = VoiceActivityDetector()
    private var preRoll: [[Float]] = []
    private var captured: [Float] = []
    private var delivered = false
    private var diagnosticPeak: Float = 0
    private var lastDiagnostic: TimeInterval = 0
    let claps: Bool
    let handsFree: Bool
    init(claps: Bool, handsFree: Bool) { self.claps = claps; self.handsFree = handsFree }

    // AVAudioEngine serializes callbacks on this tap. State never crosses into the UI thread.
    func process(_ buffer: AVAudioPCMBuffer, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> (clap: Bool, speech: [Float]?) {
        guard !delivered, let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return (false, nil) }
        let count = Int(buffer.frameLength)
        var peak: Float = 0; var squares: Float = 0
        for i in 0..<count { let value = abs(samples[i]); peak = max(peak, value); squares += value * value }
        let rms = sqrt(squares / Float(count))
        if time < AudioLog.diagnosticUntil {
            diagnosticPeak = max(diagnosticPeak, peak)
            if time - lastDiagnostic >= 1 {
                AudioLog.logger.notice("Microphone diagnostic peak: \(self.diagnosticPeak), RMS: \(rms)")
                lastDiagnostic = time; diagnosticPeak = 0
            }
        }
        if claps, detector.feed(peak: peak, rms: rms, at: time) {
            delivered = true; return (true, nil)
        }
        guard handsFree else { return (false, nil) }
        let duration = Double(count) / buffer.format.sampleRate
        let chunk = Array(UnsafeBufferPointer(start: samples, count: count))
        if speech.active { captured.append(contentsOf: chunk) }
        else {
            preRoll.append(chunk)
            let limit = max(1, Int(0.3 / duration))
            if preRoll.count > limit { preRoll.removeFirst(preRoll.count - limit) }
        }
        switch speech.feed(rms: rms, duration: duration) {
        case .start: captured = preRoll.flatMap { $0 }; preRoll.removeAll(keepingCapacity: true)
        case .finish: delivered = true; return (false, captured)
        case .discard: captured.removeAll(keepingCapacity: true); preRoll.removeAll(keepingCapacity: true)
        case .none: break
        }
        return (false, nil)
    }
}

@MainActor
final class AudioInput {
    let livePreview = LiveSpeechPreview()
    private var engine: AVAudioEngine?
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var recordingStarted: Date?
    var onClap: (() -> Void)?
    var onSpeech: ((URL, String?) -> Void)?
    var onError: ((Error) -> Void)?
    private var monitorID = UUID()
    var isRecording: Bool { recorder?.isRecording == true }
    var isMonitoring: Bool { engine != nil }
    var hasPermission: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    func permission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func startMonitoring(claps: Bool, handsFree: Bool) throws {
        if engine != nil { return }
        guard !isRecording else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw JarvisError.message("No microphone is available.") }
        let state = MonitorAudioState(claps: claps, handsFree: handsFree)
        if handsFree { livePreview.start() }
        let speechSlot = livePreview.slot
        let id = UUID(); monitorID = id
        input.installTap(onBus: 0, bufferSize: 256, format: format) { [weak self] buffer, _ in
            speechSlot.append(buffer)
            let event = state.process(buffer)
            let rate = buffer.format.sampleRate
            if event.clap || event.speech != nil {
                Task { @MainActor in
                    guard let self, self.monitorID == id else { return }
                    if event.clap { self.onClap?() }
                    else if let samples = event.speech {
                        let liveText = self.livePreview.recentText
                        self.stopMonitoring()
                        do { self.onSpeech?(try self.save(samples, sampleRate: rate), liveText) }
                        catch { self.onError?(error) }
                    }
                }
            }
        }
        self.engine = engine
        do { try engine.start() } catch { stopMonitoring(); throw error }
        AudioLog.logger.notice("Microphone monitor started; claps: \(claps), hands-free: \(handsFree), sample rate: \(format.sampleRate)")
    }
    func stopMonitoring() {
        livePreview.stop()
        monitorID = UUID()
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        engine = nil
    }
    func save(_ samples: [Float], sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-\(UUID().uuidString).wav")
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = buffer.floatChannelData?[0] else { throw JarvisError.message("Audio buffer unavailable.") }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in if let base = source.baseAddress { output.update(from: base, count: samples.count) } }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            return url
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }
    func startRecording() throws {
        stopMonitoring()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-\(UUID().uuidString).wav")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder.record() else { throw JarvisError.message("Microphone recording could not start.") }
        self.recorder = recorder; recordingURL = url; recordingStarted = Date()
    }
    func stopRecording() -> URL? {
        recorder?.stop(); recorder = nil
        let url = recordingURL; recordingURL = nil
        if let started = recordingStarted, Date().timeIntervalSince(started) < 0.35 {
            if let url { try? FileManager.default.removeItem(at: url) }; return nil
        }
        recordingStarted = nil
        return url
    }
    func cancel() {
        if let url = stopRecording() { try? FileManager.default.removeItem(at: url) }
        stopMonitoring()
    }

    static var speechModelPath: String? {
        if let pointer = Bundle.main.url(forResource: "speech-model-path", withExtension: "txt"),
           let path = try? String(contentsOf: pointer, encoding: .utf8), FileManager.default.fileExists(atPath: path) { return path }
        return nil
    }
    static var whisperPath: String? { ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"].first { FileManager.default.isExecutableFile(atPath: $0) } }

    func transcribe(_ url: URL, using modelPath: String? = nil) async throws -> String {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let model = modelPath ?? Self.speechModelPath, let executable = Self.whisperPath else { throw JarvisError.message("Local speech files are missing. Run scripts/setup-local.sh and rebuild.") }
        let normalized = url.deletingPathExtension().appendingPathExtension("16k.wav")
        defer { try? FileManager.default.removeItem(at: normalized) }
        _ = try await ProcessRunner.run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", url.path, normalized.path], timeout: 10)
        let output = url.deletingPathExtension().path
        let textURL = URL(fileURLWithPath: output + ".txt")
        defer { try? FileManager.default.removeItem(at: textURL) }
        _ = try await ProcessRunner.run(executable, ["-m", model, "-f", normalized.path, "-l", "en", "-t", "4", "-otxt", "-of", output, "-nt", "--prompt", "JARVIS, Claude, Google Chrome, Outlook, WSJ, Apple Notes, iMessage."], timeout: 45)
        try Task.checkCancellation()
        let text = (try String(contentsOf: textURL, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !["[BLANK_AUDIO]", "[Silence]", "(silence)"].contains(text) else { throw JarvisError.message("I didn’t catch any speech. Try again a little closer to the microphone.") }
        return text
    }
}
