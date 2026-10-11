import Foundation
import AVFoundation

enum VoiceRenderer {
    static func render(_ text: String, to destination: URL) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("text.txt")
        let raw = directory.appendingPathComponent("voice.aiff")
        // File input keeps private reply text out of process arguments.
        try String(text.prefix(2000)).write(to: input, atomically: true, encoding: .utf8)
        _ = try await ProcessRunner.run("/usr/bin/say", ["-v", "Samantha", "-r", "210", "-f", input.path, "-o", raw.path], timeout: 25)
        try Task.checkCancellation()
        try await Task.detached(priority: .utility) { try RoboticVoiceFilter.render(raw, to: destination) }.value
        try Task.checkCancellation()
    }
}

enum RoboticVoiceFilter {
    /// Subtle comb filtering and modulation add a metallic quality while preserving words.
    static func render(_ input: URL, to output: URL) throws {
        let source = try AVAudioFile(forReading: input)
        let format = source.processingFormat
        guard format.channelCount == 1, format.commonFormat == .pcmFormatFloat32,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw JarvisError.message("The local voice returned an unsupported audio format.")
        }
        let result = try AVAudioFile(forWriting: output, settings: format.settings)
        let firstDelay = max(1, Int(format.sampleRate * 0.007))
        let secondDelay = max(firstDelay + 1, Int(format.sampleRate * 0.013))
        var delay = [Float](repeating: 0, count: secondDelay + 1)
        var position = 0
        var frame: Int64 = 0
        while source.framePosition < source.length {
            try source.read(into: buffer, frameCount: buffer.frameCapacity)
            guard let samples = buffer.floatChannelData?[0] else { throw JarvisError.message("Could not process local voice audio.") }
            for index in 0..<Int(buffer.frameLength) {
                let dry = samples[index]
                let early = delay[(position + delay.count - firstDelay) % delay.count]
                let late = delay[(position + delay.count - secondDelay) % delay.count]
                let modulation = Float(0.82 + 0.18 * cos(2 * Double.pi * 38 * Double(frame) / format.sampleRate))
                let processed = (dry * 0.88 + early * 0.24 - late * 0.16) * modulation * 1.12
                samples[index] = max(-0.98, min(0.98, processed))
                delay[position] = dry; position = (position + 1) % delay.count; frame += 1
            }
            try result.write(from: buffer)
        }
    }
}
