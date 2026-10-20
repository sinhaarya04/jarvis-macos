import Foundation

@main struct PrepareGreeting {
    static func main() async throws {
        guard CommandLine.arguments.count >= 2 else { fatalError("Pass an output AIFF path") }
        let text = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Welcome to the office, boss."
        try await VoiceRenderer.render(text, to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
