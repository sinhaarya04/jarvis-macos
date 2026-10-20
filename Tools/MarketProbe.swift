import Foundation

@main struct MarketProbe {
    static func main() async throws {
        let start = Date()
        let scope = MarketScope(rawValue: CommandLine.arguments.dropFirst().first ?? "india") ?? .india
        let report = try await MarketService().report(scope, overnight: CommandLine.arguments.contains("--overnight"))
        print("Fetch time: \(String(format: "%.2f", Date().timeIntervalSince(start))) seconds")
        print(report.spoken)
        print("\nSources:\n" + report.details)
    }
}
