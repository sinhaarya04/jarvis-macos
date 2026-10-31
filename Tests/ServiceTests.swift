import Foundation

@main struct ServiceTests {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
        // Synthetic values only: parser coverage never reads files or changes Keychain.
        let syntheticKey = "sk-ant-" + String(repeating: "x", count: 40)
        for assignment in [
            "ANTHROPIC_API_KEY=\(syntheticKey)",
            "export ANTHROPIC_API_KEY=\(syntheticKey)",
            "  export\tANTHROPIC_API_KEY = \(syntheticKey)  ",
            "ANTHROPIC_API_KEY=\(syntheticKey) # work account",
            "export ANTHROPIC_API_KEY=\(syntheticKey)\t# work account",
            "ANTHROPIC_API_KEY='\(syntheticKey)'",
            "ANTHROPIC_API_KEY=\"\(syntheticKey)\"",
            "export ANTHROPIC_API_KEY='\(syntheticKey)' # note",
            "export ANTHROPIC_API_KEY=\"\(syntheticKey)\" # note",
            "# ANTHROPIC_API_KEY=ignored\r\nOTHER=value\r\nexport ANTHROPIC_API_KEY=\(syntheticKey) # note\r\n"
        ] {
            check(try ClaudeCredentials.key(inEnvironment: assignment) == syntheticKey, "literal environment key import")
        }
        for invalid in [
            "# ANTHROPIC_API_KEY=\(syntheticKey)",
            "exportANTHROPIC_API_KEY=\(syntheticKey)",
            "OTHER_ANTHROPIC_API_KEY=\(syntheticKey)",
            "ANTHROPIC_API_KEY=\(syntheticKey)\nexport ANTHROPIC_API_KEY=\(syntheticKey)",
            "ANTHROPIC_API_KEY=\nexport ANTHROPIC_API_KEY=\(syntheticKey)",
            "ANTHROPIC_API_KEY=",
            "ANTHROPIC_API_KEY=sk-ant-short",
            "ANTHROPIC_API_KEY='\(syntheticKey)",
            "ANTHROPIC_API_KEY=\"\(syntheticKey)'",
            "ANTHROPIC_API_KEY=\(syntheticKey)'",
            "ANTHROPIC_API_KEY=\(syntheticKey) unexpected text",
            "ANTHROPIC_API_KEY=\(syntheticKey)\tunexpected",
            "ANTHROPIC_API_KEY='\(syntheticKey) # not a comment'",
            "ANTHROPIC_API_KEY=\"\(syntheticKey)\" trailing text",
            "ANTHROPIC_API_KEY=$OTHER_KEY",
            "ANTHROPIC_API_KEY=$(printf ignored)",
            "ANTHROPIC_API_KEY=`printf ignored`"
        ] {
            do { _ = try ClaudeCredentials.key(inEnvironment: invalid); fatalError("invalid environment key accepted") }
            catch { check(!error.localizedDescription.contains(syntheticKey), "key parser errors never echo key material") }
        }
        let now = ISO8601DateFormatter().date(from: "2026-09-22T12:00:00Z")!
        check(MarketParsing.inOvernightWindow(now.addingTimeInterval(-11 * 3600), now: now), "overnight headline included")
        check(!MarketParsing.inOvernightWindow(now.addingTimeInterval(-13 * 3600), now: now), "older headline excluded")
        check(!MarketParsing.inOvernightWindow(now.addingTimeInterval(60), now: now), "future headline excluded")
        let payload: [String: Any] = ["chart": ["result": [["meta": ["regularMarketPrice": 120.0, "regularMarketTime": now.timeIntervalSince1970, "chartPreviousClose": 50.0, "exchangeTimezoneName": "UTC"], "timestamp": [now.addingTimeInterval(-86400).timeIntervalSince1970, now.timeIntervalSince1970], "indicators": ["quote": [["close": [100.0, 120.0]]]]]]]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let quote = try MarketParsing.quote(data, name: "Test", source: "https://example.test", now: now)
        check(abs((quote.changePercent ?? 0) - 20) < 0.0001, "previous session, not start-of-range comparison")
        do { _ = try MarketParsing.quote(data, name: "Test", source: "", now: now.addingTimeInterval(5 * 86400)); fatalError("stale quote accepted") } catch { count += 1 }
        do { _ = try MarketParsing.quote(data, name: "Test", source: "", now: now.addingTimeInterval(-600)); fatalError("future quote accepted") } catch { count += 1 }
        let rss = """
        <rss><channel><item><title><![CDATA[Nifty &amp; Sensex move]]></title><link>https://example.test/story</link><pubDate>Tue, 22 Sep 2026 11:00:00 GMT</pubDate></item>
        <item><title>Old</title><link>https://example.test/old</link><pubDate>Tue, 01 Sep 2026 11:00:00 GMT</pubDate></item>
        <item><title>Offsite</title><link>https://evil.test/story</link><pubDate>Tue, 22 Sep 2026 11:00:00 GMT</pubDate></item></channel></rss>
        """
        let items = MarketRSSParser(publisher: "Test", allowedHost: "example.test", now: now).parse(Data(rss.utf8))
        check(items.count == 1 && items[0].title == "Nifty & Sensex move", "RSS CDATA, dates, and publisher boundary")
        let html = "<h4>2026</h4><tbody><tr><td>September 17</td><td>25</td><td>0</td><td>3.75-4.00</td></tr></tbody>"
        check(MarketParsing.fedRate(html, now: now)?.contains("3.75 to 4.00") == true, "official Fed table")
        check(MarketParsing.rbiRate("<td>Policy Repo Rate</td><td>: 5.25%</td>")?.contains("5.25") == true, "official RBI label")
        check(MarketParsing.rbiRate("Policy Repo Rate: 999%") == nil, "invalid rate rejected")
        var stream = ClaudeStreamAccumulator()
        _ = try stream.accept("event: message_start")
        _ = try stream.accept("data: {\"type\":\"ping\"}")
        _ = try stream.accept("data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello boss.\"}}")
        do { _ = try stream.finishedText(); fatalError("partial stream accepted") } catch { count += 1 }
        _ = try stream.accept("data: {\"type\":\"message_stop\"}")
        check(try stream.finishedText() == "Hello boss.", "completed Claude stream")
        do { _ = try stream.accept("data: {\"type\":\"error\",\"error\":{\"message\":\"private diagnostic\"}}"); fatalError("stream error ignored") }
        catch { check(!error.localizedDescription.contains("private diagnostic"), "stream errors redact provider detail") }
        let valid: [String: Any] = ["choice": "open", "confidence": 0.9, "probabilities": ["open": 0.9, "wait": 0.1]]
        check(try JevValidation.choice(valid, allowed: ["open", "wait"]) == "open", "typed Jev choice")
        for invalid: [String: Any] in [
            ["choice": "delete", "confidence": 1.0, "probabilities": ["delete": 1.0]],
            ["choice": "open", "confidence": 0.1, "probabilities": ["open": 0.9, "wait": 0.1]],
            ["choice": "wait", "confidence": 0.9, "probabilities": ["open": 0.9, "wait": 0.1]]
        ] {
            do { _ = try JevValidation.choice(invalid, allowed: ["open", "wait"]); fatalError("invalid Jev choice accepted") } catch { count += 1 }
        }
        print("Passed \(count) service checks; no network or API calls.")
    }
}
