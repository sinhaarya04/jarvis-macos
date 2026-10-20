import Foundation
import AVFoundation

/// Exercises the actual capture buffer → silence gate → WAV → Whisper → wake phrase path.
/// Uses synthetic audio, never a live microphone, and does not execute the resulting action.
@main struct AudioSmoke {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count >= 3 else { fatalError("Usage: audio-smoke fixture.wav model.bin [direct-command.wav]") }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
        let state = MonitorAudioState(claps: true, handsFree: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 256)!
        let clapState = MonitorAudioState(claps: true, handsFree: true)
        buffer.frameLength = 256
        buffer.floatChannelData![0].update(repeating: 0, count: 256)
        buffer.floatChannelData![0][0] = 0.9
        precondition(!clapState.process(buffer, at: 1).clap)
        buffer.floatChannelData![0][0] = 0
        precondition(!clapState.process(buffer, at: 1.016).clap)
        buffer.floatChannelData![0][0] = 0.9
        precondition(!clapState.process(buffer, at: 1.4).clap)
        buffer.floatChannelData![0][0] = 0
        let clapped = clapState.process(buffer, at: 1.416)
        precondition(clapped.clap && clapped.speech == nil, "Claps must bypass speech transcription")
        print("PASS: second clap recognized directly, with no speech-transcription wait.")
        var captured: [Float]?
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: 256)
            let result = state.process(buffer)
            precondition(!result.clap, "Speech accidentally triggered claps")
            if let samples = result.speech { captured = samples }
        }
        buffer.frameLength = 256
        buffer.floatChannelData![0].update(repeating: 0, count: 256)
        for _ in 0..<Int(file.processingFormat.sampleRate / 128) {
            if let samples = state.process(buffer).speech { captured = samples }
        }
        guard let captured else { fatalError("Speech gate did not finish the phrase") }
        let audio = AudioInput()
        let sample = try audio.save(captured, sampleRate: file.processingFormat.sampleRate)
        let started = Date()
        let text = try await audio.transcribe(sample, using: CommandLine.arguments[2])
        let command = WakePhrase.command(in: text)
        print("Transcript: \(text)")
        guard let command, CommandParser.parse(command) == .open("Claude") else { fatalError("Wake phrase / intended command did not survive transcription") }
        precondition(!FileManager.default.fileExists(atPath: sample.path), "Temporary audio not removed")
        print(String(format: "PASS: hands-free synthetic command, %.2fs transcription; no app action executed.", Date().timeIntervalSince(started)))
        let reply = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-voice-test-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: reply) }
        try await VoiceRenderer.render("Welcome to the office, boss.", to: reply)
        let voiceFile = try AVAudioFile(forReading: reply)
        precondition(voiceFile.length > 0 && voiceFile.processingFormat.channelCount == 1)
        let voiceText = try await audio.transcribe(reply, using: CommandLine.arguments[2])
        precondition(voiceText.lowercased().contains("welcome to the office") && voiceText.lowercased().contains("boss"), "Robotic voice must preserve understandable words")
        print("PASS: robotic female voice renders locally and remains intelligible to the speech recognizer.")
        if CommandLine.arguments.count >= 4 {
            let direct = try await audio.transcribe(URL(fileURLWithPath: CommandLine.arguments[3]), using: CommandLine.arguments[2])
            print("Direct-mode transcript: \(direct)")
            guard let accepted = WakePhrase.command(in: direct, followUp: true),
                  case .sequence(let commands) = CommandParser.parse(accepted), commands.count == 2,
                  case .open(let first) = commands[0], case .open(let second) = commands[1],
                  OpenTargetPolicy.applications[OpenTargetPolicy.normalize(first)] == "com.google.Chrome",
                  OpenTargetPolicy.website(second)?.host == "www.instagram.com" else { fatalError("Direct Chrome + Instagram voice command failed") }
            print("PASS: direct speech needs no wake word or keypress and routes Chrome + Instagram separately; no app action executed.")
        }
        if CommandLine.arguments.count >= 5 {
            let office = try await audio.transcribe(URL(fileURLWithPath: CommandLine.arguments[4]), using: CommandLine.arguments[2])
            print("Office-mode transcript: \(office)")
            guard let accepted = WakePhrase.command(in: office, followUp: true), CommandParser.parse(accepted) == .briefing else { fatalError("Spoken start-work phrase didn't route to Office mode") }
            print("PASS: the spoken start-work phrase and menu Office mode route to the same briefing.")
        }
    }
}
