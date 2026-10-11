import Foundation

struct MarketReport { let spoken: String; let details: String }
struct MarketQuote {
    let name: String
    let price: Double
    let changePercent: Double?
    let timestamp: Date
    let timezone: TimeZone
    let source: String
    let yield: Bool
    var spoken: String {
        let value = MarketParsing.number(price, digits: yield ? 2 : name == "Bitcoin" ? 0 : 2)
        let unit = yield ? " percent" : name == "Bitcoin" ? " U.S. dollars" : ""
        let change = changePercent.map { ", \($0 >= 0 ? "up" : "down") \(MarketParsing.number(abs($0), digits: 2)) percent versus the previous session" } ?? ""
        return "\(name), \(value)\(unit)\(yield ? "" : change), as of \(MarketParsing.date(timestamp, timezone: timezone))."
    }
}
struct MarketHeadline {
    let title: String
    let url: String
    let published: Date
    let publisher: String
}

enum MarketParsing {
    static func inOvernightWindow(_ published: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(published)
        return age >= 0 && age <= 12 * 3600
    }
    static func number(_ value: Double, digits: Int) -> String {
        let formatter = NumberFormatter(); formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal; formatter.minimumFractionDigits = digits; formatter.maximumFractionDigits = digits
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
    static func date(_ date: Date, timezone: TimeZone = .current) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timezone
        f.dateFormat = "MMM d, h:mm a z"; return f.string(from: date)
    }
    static func captures(_ pattern: String, _ text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
        }
    }
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func quote(_ data: Data, name: String, source: String, yield: Bool = false, now: Date = Date()) throws -> MarketQuote {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chart = root["chart"] as? [String: Any], let result = (chart["result"] as? [[String: Any]])?.first,
              let meta = result["meta"] as? [String: Any], let price = meta["regularMarketPrice"] as? Double,
              let epoch = meta["regularMarketTime"] as? Double, price.isFinite, price > 0 else { throw JarvisError.message("\(name) quote unavailable.") }
        let timestamp = Date(timeIntervalSince1970: epoch)
        guard now.timeIntervalSince(timestamp) >= -300, now.timeIntervalSince(timestamp) < 4 * 86400 else {
            throw JarvisError.message("\(name)'s quote is too old to use.")
        }
        // chartPreviousClose is the start of the requested range, NOT yesterday's close.
        // Use only an explicitly named previous close or the previous daily bar.
        var percent = meta["regularMarketChangePercent"] as? Double
        var previous = meta["previousClose"] as? Double ?? meta["regularMarketPreviousClose"] as? Double
        let zone = TimeZone(identifier: meta["exchangeTimezoneName"] as? String ?? "UTC") ?? TimeZone(secondsFromGMT: 0)!
        if percent == nil && previous == nil,
           let times = result["timestamp"] as? [Double], let indicators = result["indicators"] as? [String: Any],
           let series = (indicators["quote"] as? [[String: Any]])?.first, let closes = series["close"] as? [Any] {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            let tradingDay = calendar.startOfDay(for: timestamp)
            for i in times.indices.reversed() where i < closes.count {
                if Date(timeIntervalSince1970: times[i]) < tradingDay, let close = closes[i] as? Double, close > 0 {
                    previous = close; break
                }
            }
        }
        if percent == nil, let previous, previous > 0 { percent = (price / previous - 1) * 100 }
        if let p = percent, !p.isFinite { percent = nil }
        return MarketQuote(name: name, price: price, changePercent: percent, timestamp: timestamp, timezone: zone, source: source, yield: yield)
    }
    static func fedRate(_ html: String, now: Date = Date()) -> String? {
        for section in captures("<h4[^>]*>\\s*(20[0-9]{2})\\s*</h4>(.*?)</tbody>", html) {
            for row in captures("<tr[^>]*>(.*?)</tr>", section[1]) {
                let cells = captures("<td[^>]*>(.*?)</td>", row[0]).map { clean($0[0]) }
                guard cells.count == 4, let values = captures("^([0-9]+(?:\\.[0-9]+)?)[–-]([0-9]+(?:\\.[0-9]+)?)$", cells[3]).first,
                      let low = Double(values[0]), let high = Double(values[1]), low >= 0, high >= low, high <= 25 else { continue }
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "America/New_York"); f.dateFormat = "MMMM d yyyy"
                guard let effective = f.date(from: cells[0] + " " + section[0]), effective <= now else { continue }
                return "The Federal Reserve lists a target range of \(number(low, digits: 2)) to \(number(high, digits: 2)) percent, effective \(cells[0]), \(section[0])."
            }
        }
        return nil
    }
    static func rbiRate(_ html: String) -> String? {
        guard let value = captures("Policy Repo Rate\\s*:?\\s*([0-9]+(?:\\.[0-9]+)?)\\s*%", clean(html)).first?.first,
              let number = Double(value), number >= 0, number <= 25 else { return nil }
        return "The Reserve Bank of India currently lists its repo rate at \(value) percent."
    }
}

final class MarketRSSParser: NSObject, XMLParserDelegate {
    private var item: [String: String]?
    private var field: String?
    private var articles: [MarketHeadline] = []
    private let publisher: String
    private let allowedHost: String
    private let now: Date
    init(publisher: String, allowedHost: String, now: Date = Date()) { self.publisher = publisher; self.allowedHost = allowedHost; self.now = now }
    func parse(_ data: Data) -> [MarketHeadline] {
        let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = self
        guard parser.parse() else { return [] }; return articles
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if elementName == "item" { item = [:] }
        if item != nil && ["title", "link", "pubDate"].contains(elementName) { field = elementName; item?[elementName] = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if let field { item?[field, default: ""] += string } }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { if let text = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: text) } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == field { field = nil }
        guard elementName == "item", let current = item else { return }
        defer { item = nil; field = nil }
        let title = MarketParsing.clean(current["title"] ?? "")
        let link = (current["link"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        guard !title.isEmpty, let date = f.date(from: current["pubDate"] ?? ""), now.timeIntervalSince(date) >= -300,
              now.timeIntervalSince(date) <= 4 * 86400, let url = URL(string: link), url.scheme == "https",
              let host = url.host, host == allowedHost || host.hasSuffix("." + allowedHost) else { return }
        articles.append(MarketHeadline(title: title, url: link, published: date, publisher: publisher))
    }
}

actor MarketService {
    private let session: URLSession
    private struct Feed { let name: String; let url: String; let host: String }
    private struct Part { let order: Int; let spoken: String; let detail: String }
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6; config.timeoutIntervalForResource = 8
        session = URLSession(configuration: config)
    }
    private func fetch(_ address: String) async throws -> Data {
        var request = URLRequest(url: URL(string: address)!); request.setValue("Mozilla/5.0 JARVIS/0.3", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000 else { throw JarvisError.message("Market source unavailable.") }
        return data
    }
    func report(_ scope: MarketScope, overnight: Bool = false) async throws -> MarketReport {
        let now = Date()
        var parts = await withTaskGroup(of: Part.self, returning: [Part].self) { group in
            var quotes: [(String, String, Bool)] = []
            if scope == .all { quotes += [("^GSPC", "S and P 500", false), ("^IXIC", "Nasdaq Composite", false)] }
            if scope == .all || scope == .india { quotes += [("^NSEI", "Nifty 50", false), ("^BSESN", "Sensex", false)] }
            if scope == .all || scope == .rates { quotes += [("^TNX", "U.S. ten-year Treasury yield", true)] }
            for (index, quote) in quotes.enumerated() {
                group.addTask {
                    let symbol = quote.0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
                    let url = "https://query1.finance.yahoo.com/v8/finance/chart/\(symbol)?interval=1d&range=5d"
                    do {
                        let parsed = try MarketParsing.quote(await self.fetch(url), name: quote.1, source: url, yield: quote.2, now: now)
                        return Part(order: index, spoken: parsed.spoken, detail: parsed.spoken + "\n" + url)
                    } catch { return Part(order: index, spoken: "\(quote.1) is unavailable right now.", detail: "\(quote.1): source unavailable; no old value substituted.") }
                }
            }
            if scope == .all || scope == .bitcoin {
                group.addTask {
                    let url = "https://api.coinbase.com/v2/prices/BTC-USD/spot"
                    do {
                        let data = try await self.fetch(url)
                        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                        guard let value = root?["data"] as? [String: String], value["base"] == "BTC", value["currency"] == "USD",
                              let raw = value["amount"], let price = Double(raw), price.isFinite, price > 0 else { throw JarvisError.message("Invalid Bitcoin quote") }
                        let text = "Coinbase's Bitcoin spot quote is \(MarketParsing.number(price, digits: 0)) U.S. dollars, retrieved at \(MarketParsing.date(Date()))."
                        return Part(order: 9, spoken: text, detail: text + "\n" + url)
                    } catch { return Part(order: 9, spoken: "Bitcoin's current quote is unavailable.", detail: "Coinbase spot request failed.") }
                }
            }
            if scope == .all || scope == .rates {
                group.addTask { await self.ratePart(fed: true, now: now) }
            }
            if scope == .all || scope == .india || scope == .rates { group.addTask { await self.ratePart(fed: false, now: now) } }
            if scope == .all || scope == .india || scope == .news { group.addTask { await self.newsPart(india: scope == .india, now: now, overnight: overnight || scope == .news) } }
            var results: [Part] = []; for await part in group { results.append(part) }; return results
        }
        try Task.checkCancellation()
        parts.sort { $0.order < $1.order }
        let heading = scope == .india ? "Here's your Indian market briefing. These are the latest available quotes; prices may be delayed." : scope == .all ? "Here's your market briefing. These are the latest available quotes; prices may be delayed." : "Here's the latest available update."
        return MarketReport(spoken: ([heading] + parts.map(\.spoken)).joined(separator: "\n"),
                            details: "Retrieved \(MarketParsing.date(Date())).\n\n" + parts.map(\.detail).joined(separator: "\n\n"))
    }
    private func ratePart(fed: Bool, now: Date) async -> Part {
        let url = fed ? "https://www.federalreserve.gov/monetarypolicy/openmarket.htm" : "https://www.rbi.org.in/"
        let name = fed ? "Federal Reserve target rate" : "RBI repo rate"
        if let data = try? await fetch(url), let html = String(data: data, encoding: .utf8),
           let text = fed ? MarketParsing.fedRate(html, now: now) : MarketParsing.rbiRate(html) {
            return Part(order: fed ? 7 : 8, spoken: text, detail: text + "\nChecked \(MarketParsing.date(now)).\n" + url)
        }
        return Part(order: fed ? 7 : 8, spoken: "The \(name) could not be checked.", detail: "\(name): official source unavailable.")
    }
    private func newsPart(india: Bool, now: Date, overnight: Bool) async -> Part {
        let feeds = india ? [Feed(name: "The Economic Times", url: "https://economictimes.indiatimes.com/markets/rssfeeds/1977021501.cms", host: "economictimes.indiatimes.com")]
            : [Feed(name: "The Wall Street Journal", url: "https://feeds.content.dowjones.io/public/rss/RSSMarketsMain", host: "wsj.com"), Feed(name: "CNBC", url: "https://www.cnbc.com/id/100003114/device/rss/rss.html", host: "cnbc.com"), Feed(name: "The Economic Times", url: "https://economictimes.indiatimes.com/markets/rssfeeds/1977021501.cms", host: "economictimes.indiatimes.com")]
        let articles = await withTaskGroup(of: [MarketHeadline].self, returning: [MarketHeadline].self) { group in
            for feed in feeds { group.addTask {
                guard let data = try? await self.fetch(feed.url) else { return [] }
                return MarketRSSParser(publisher: feed.name, allowedHost: feed.host, now: now).parse(data)
            } }
            var result: [MarketHeadline] = []; for await items in group { result += items }; return result
        }
        // Prioritize broad market/index and policy coverage, then recency; this is a headline digest, not a claim of universal importance.
        func score(_ article: MarketHeadline) -> Int {
            let title = article.title.lowercased()
            let topics = india ? ["nifty", "sensex", "stock market", "rbi", "rupee", "fii", "inflation"] : ["stock market", "nasdaq", "s&p", "federal reserve", "interest rate", "oil", "inflation"]
            return topics.filter(title.contains).count * 10 + (article.publisher == "The Wall Street Journal" ? 2 : 0)
        }
        var seen = Set<String>(); var topics = Set<String>()
        let ranked = articles.filter { !overnight || MarketParsing.inOvernightWindow($0.published, now: now) }
            .sorted { score($0) == score($1) ? $0.published > $1.published : score($0) > score($1) }
        let chosen = Array(ranked.filter { article in
            guard seen.insert(article.title.lowercased()).inserted else { return false }
            let title = article.title.lowercased()
            let topic: String?
            if title.contains("stock market") || title.contains("stocks rise") || title.contains("stocks fall") { topic = "equities" }
            else if title.hasPrefix("oil ") { topic = "oil" }
            else if title.hasPrefix("rupee ") { topic = "rupee" }
            else { topic = nil }
            return topic.map { topics.insert($0).inserted } ?? true
        }.prefix(overnight ? 5 : 3))
        guard !chosen.isEmpty else { return Part(order: 10, spoken: overnight ? "I couldn't verify any market headlines published in the past twelve hours." : "I couldn't retrieve recent market headlines. Please try again shortly.", detail: "News feeds unavailable or no dated items in the requested window.") }
        let spoken = "\(chosen.count) market headlines\(overnight ? " from the past twelve hours" : ""). " + chosen.enumerated().map {
            "\($0.offset + 1). \($0.element.publisher): \($0.element.title)."
        }.joined(separator: " ")
        let detail = chosen.map { "\($0.title)\n\($0.publisher) · \(MarketParsing.date($0.published))\n\($0.url)" }.joined(separator: "\n\n")
        return Part(order: 10, spoken: spoken, detail: "Headline briefing, not full-article summaries.\n" + detail)
    }
}
