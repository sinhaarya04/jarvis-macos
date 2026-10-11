import Foundation

final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func launch(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        self.process = process
        try process.run()
    }
    func cancel() {
        lock.lock(); cancelled = true; let p = process; lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
}

enum ProcessRunner {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) async throws -> String {
        let handle = ProcessHandle()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                try handle.launch(process)
                let watchdog = DispatchWorkItem { handle.cancel() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                defer { watchdog.cancel() }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(data: data, encoding: .utf8) ?? ""
                guard process.terminationStatus == 0 else {
                    throw JarvisError.message(String(text.suffix(1200)).isEmpty ? "The operation stopped or timed out." : String(text.suffix(1200)))
                }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }.value
        } onCancel: { handle.cancel() }
    }
}
