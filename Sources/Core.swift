import Foundation

struct MessageRecipient: Identifiable {
    let id = UUID()
    let name: String
    let handle: String
    let requiresConfirmation: Bool

    static func isExactName(_ query: String, givenName: String, familyName: String) -> Bool {
        func normalized(_ value: String) -> String {
            value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        }
        let query = normalized(query)
        guard !query.isEmpty else { return false }
        return [givenName, familyName, "\(givenName) \(familyName)"].contains { normalized($0) == query }
    }

    /// A unique prefix/word match still needs an explicit choice before sending.
    static func automaticRecipient(in matches: [MessageRecipient]) -> MessageRecipient? {
        guard matches.count == 1, let recipient = matches.first, !recipient.requiresConfirmation else { return nil }
        return recipient
    }
}

enum MarketScope: String { case all, india, bitcoin, rates, news }

enum Command: Equatable {
    case open(String), switchTab(String), note(String, String), type(String)
    case message(String, String), summarize(String), summarizeSelection, summarizePage
    case briefing, greet, hearingCheck, help, stop, chat(String), browse(String)
    case markets(MarketScope)
    case search(String)
    case instagram(InstagramCommand)
    case sequence([Command])

    var canUseLiveTranscript: Bool {
        switch self {
        case .open(let target): return OpenTargetPolicy.known(target)
        case .search, .switchTab, .markets, .hearingCheck, .help, .greet, .stop, .briefing: return true
        case .sequence(let commands): return !commands.isEmpty && commands.allSatisfy(\.canUseLiveTranscript)
        default: return false
        }
    }
}

enum CommandParser {
    static func parse(_ input: String) -> Command {
        let original = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let wakeStripped = original.replacingOccurrences(of: "^(?:hey\\s+)?jarvis[,.:!]?\\s+", with: "", options: [.regularExpression, .caseInsensitive])
        let text = wakeStripped.replacingOccurrences(of: "^(?:(?:alright|all right|okay|ok)[, ]+)?(?:(?:can|could|would) (?:you|u) (?:please )?|please )?(?=(?:open|launch|visit|go to|navigate to|search|find|look up|google|switch|make|take|create|save|send|message|draft|type|dictate|summari[sz]e)\\b)", with: "", options: [.regularExpression, .caseInsensitive])
        let lower = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!? "))
        if ["stop", "cancel", "be quiet"].contains(lower) { return .stop }
        if ["help", "what can you do"].contains(lower) { return .help }
        if ["brief me", "morning briefing", "start my day", "office mode", "aryan here to start working", "aryan is here to start working", "aryan here, let's start working", "aryan here let's start working", "i'm here to start working", "i am here to start working", "what happened to markets overnight", "what happened in markets overnight", "what happened while i was sleeping"].contains(lower) { return .briefing }
        if ["hello", "welcome", "test greeting"].contains(lower) { return .greet }
        if ["can you hear me", "can u hear me", "do you hear me", "are you listening", "are you able to hear me", "can you hear me now"].contains(lower) { return .hearingCheck }
        if ["summarize this page", "summarise this page", "summarize the page"].contains(lower) { return .summarizePage }
        if ["summarize this", "summarize selection", "summarize this email", "summarise this email"].contains(lower) { return .summarizeSelection }
        if let instagram = InstagramIntent.parse(text) { return .instagram(instagram) }
        // Split explicit opening clauses before interpreting an app name. Never split note/message bodies.
        if lower.hasPrefix("open ") || lower.hasPrefix("launch ") || lower.hasPrefix("go to ") || lower.hasPrefix("visit ") {
            let separated = text.replacingOccurrences(of: "[, ]+(?:and then|and|then)\\s+(?=(?:open|launch|visit|go to|navigate to|search|look up|google)\\b)", with: "\u{1f}", options: [.regularExpression, .caseInsensitive])
            let clauses = separated.components(separatedBy: "\u{1f}")
            if clauses.count > 1 && clauses.count <= 4 {
                let commands = clauses.map(parse)
                if commands.allSatisfy({ switch $0 { case .open, .search: return true; default: return false } }) { return .sequence(commands) }
            }
            if let m = capture("^(?:open|launch) (.+?) and (.+?)[.!?]?$", text),
               OpenTargetPolicy.known(m[0]), OpenTargetPolicy.known(m[1]) { return .sequence([.open(m[0]), .open(m[1])]) }
        }
        if let m = capture("^((?:open|launch).+?)\\s+and\\s+((?:make|create|take|save)(?: a)? note.+)$", text),
           case .open(let name) = parse(m[0]), case .note(let title, let body) = parse(m[1]) {
            return .sequence([.open(name), .note(title, body)])
        }
        if let m = capture("^(?:browser|browse):\\s*(.+)$", text) { return .browse(m[0]) }
        if let m = capture("^(?:type|dictate)(?: this)?[ :]+(.+)$", text) { return .type(m[0]) }
        if let m = capture("^(?:create|make|take|save)(?: a)? note(?: called| titled)?[ :]+([^:]+):\\s*(.+)$", text) { return .note(m[0], m[1]) }
        if let m = capture("^(?:create|make|take|save)(?: a)? note[ :]+(.+)$", text) { return .note("JARVIS note", m[0]) }
        if let m = capture("^send (?:an? )?(?:imessage|message) to (.+?)(?::\\s*| saying\\s+)(.+)$", text) { return .message(m[0], m[1]) }
        if let m = capture("^switch to (?:the )?(.+?)(?: tab)?[.!]?$", text) { return .switchTab(m[0]) }
        if let m = capture("^(?:search(?: (?:google|the web|in chrome|on google|on chrome))?(?: for)?|look up|google)[ :]+(.+?)(?: (?:on|in) (?:google )?chrome)?[.!?]?$", text) { return .search(m[0]) }
        if let m = capture("^(?:open|launch|visit|go to|navigate to)(?: up)?[, ]+(?:the )?(.+?)(?: app)?(?:,? (?:(?:in|on|using|with) (?:the )?(?:google )?chrome|and chrome|on it|in it))?[.!?]?$", text) { return .open(m[0]) }
        if let m = capture("^summari[sz]e[ :]+(.+)$", text) { return .summarize(m[0]) }
        if let scope = marketScope(lower) { return .markets(scope) }
        return .chat(text)
    }

    private static func marketScope(_ text: String) -> MarketScope? {
        // Deliberately follows all explicit action parsers: quoted news in a note/message is still data.
        let request = text.range(of: "\\b(news|headlines?|update|updates|briefing|price|prices|quote|quotes|trading|market|markets|outlook|doing|today|latest|rate|rates)\\b", options: .regularExpression) != nil
        guard request else { return nil }
        if text.range(of: "\\b(india|indian|nifty|sensex|nse|bse)\\b", options: .regularExpression) != nil { return .india }
        if text.range(of: "\\b(bitcoin|btc)\\b", options: .regularExpression) != nil { return .bitcoin }
        if text.range(of: "\\b(interest|fed|federal reserve|rbi|repo|treasury)\\b", options: .regularExpression) != nil { return .rates }
        if text.range(of: "\\b(markets?|stocks?|financial|finance|wall street|wsj)\\b", options: .regularExpression) != nil { return .all }
        if text.range(of: "\\b(news|headlines?)\\b", options: .regularExpression) != nil { return .news }
        return nil
    }

    private static func capture(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let values = (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) } }
        return values.allSatisfy { !$0.isEmpty } ? values : nil
    }
}

enum OfficeGreeting {
    static func text(at date: Date = Date(), calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        let period = hour >= 5 && hour < 12 ? "morning" : hour >= 12 && hour < 17 ? "afternoon" : "evening"
        return "Good \(period), Aryan. Here's your catch-up from the past twelve hours."
    }
}

enum OpenTargetPolicy {
    static let applications = ["chrome": "com.google.Chrome", "google chrome": "com.google.Chrome", "google chrome browser": "com.google.Chrome", "chrome browser": "com.google.Chrome", "outlook": "com.microsoft.Outlook", "microsoft outlook": "com.microsoft.Outlook", "notes": "com.apple.Notes", "apple notes": "com.apple.Notes", "messages": "com.apple.MobileSMS", "imessage": "com.apple.MobileSMS", "safari": "com.apple.Safari", "finder": "com.apple.finder", "calendar": "com.apple.iCal", "music": "com.apple.Music"]
    static let websites = ["instagram": "https://www.instagram.com/", "insta": "https://www.instagram.com/", "instgram": "https://www.instagram.com/", "insta gram": "https://www.instagram.com/", "youtube": "https://www.youtube.com/", "you tube": "https://www.youtube.com/", "claude": "https://claude.ai/", "wsj": "https://www.wsj.com/", "wall street journal": "https://www.wsj.com/", "gmail": "https://mail.google.com/", "outlook web": "https://outlook.office.com/mail/", "google": "https://www.google.com/", "chatgpt": "https://chatgpt.com/", "chat gpt": "https://chatgpt.com/", "linkedin": "https://www.linkedin.com/", "linked in": "https://www.linkedin.com/", "reddit": "https://www.reddit.com/", "twitter": "https://x.com/", "x": "https://x.com/", "facebook": "https://www.facebook.com/", "whatsapp": "https://web.whatsapp.com/", "door dash": "https://www.doordash.com/", "doordash": "https://www.doordash.com/", "uber eats": "https://www.ubereats.com/"]
    static func normalize(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,!? "))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "^(?:the )|(?: app| application| please)$", with: "", options: .regularExpression)
    }
    static func website(_ name: String) -> URL? {
        let clean = normalize(name)
        if let address = websites[clean] { return URL(string: address) }
        guard !clean.contains(" "), clean.contains(".") else { return nil }
        let literal = name.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?"))
        let address = literal.contains("://") ? literal : "https://" + literal
        guard let url = URL(string: address), url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host, host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return nil }
        return url
    }
    static func known(_ name: String) -> Bool { applications[normalize(name)] != nil || website(name) != nil }
}

enum EarlyAppIntent {
    /// Only a known, reversible app launch may run from partial speech. No generated commands.
    static func app(in transcript: String) -> String? {
        guard let command = WakePhrase.command(in: transcript) else { return nil }
        let pattern = "^(?:(?:alright|all right|okay|ok)[, ]+)?(?:(?:can|could|would) (?:you|u) (?:please )?|please )?(?:open|launch)(?: up)? (?:the )?(notes|chrome|safari|outlook|calendar|finder|claude|messages)(?: app)?(?:[,.!?]|$| (?:and|in)\\b)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              let range = Range(match.range(at: 1), in: command) else { return nil }
        return String(command[range]).lowercased()
    }
}

/// Produces short speech chunks without speaking partial numbers or repeating streamed text.
struct SpeechChunks {
    private var consumed = 0
    mutating func consume(_ full: String, final: Bool = false) -> [String] {
        guard full.count >= consumed else { return [] }
        var pending = String(full.dropFirst(consumed)); var result: [String] = []
        while !pending.isEmpty {
            var boundary: String.Index?
            if let regex = try? NSRegularExpression(pattern: "[.!?](?=\\s)"),
               let match = regex.matches(in: pending, range: NSRange(pending.startIndex..., in: pending)).first(where: { $0.range.location >= 30 }),
               let range = Range(match.range, in: pending) { boundary = range.upperBound }
            if boundary == nil, pending.count > 300 {
                boundary = pending.prefix(300).lastIndex(of: " ")
            }
            if boundary == nil && final { boundary = pending.endIndex }
            guard let end = boundary else { break }
            let chunk = String(pending[..<end]); consumed += chunk.count; pending = String(pending[end...])
            let clean = chunk.replacingOccurrences(of: "https?://\\S+", with: "", options: .regularExpression)
                .replacingOccurrences(of: "[*#`]+", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { result.append(clean) }
        }
        return result
    }
}

/// A pulse is accepted only after it ends, which rejects speech and sustained noise.
struct ClapDetector {
    var threshold: Float = 0.22
    private var pulseStart: TimeInterval?
    private var firstClap: TimeInterval?
    private var cooldownUntil: TimeInterval = 0
    private var lastTime: TimeInterval = 0

    mutating func reset() { pulseStart = nil; firstClap = nil; cooldownUntil = 0; lastTime = 0 }

    mutating func feed(peak: Float, rms: Float, at time: TimeInterval) -> Bool {
        if time < lastTime { reset() }
        lastTime = time
        guard time >= cooldownUntil else { return false }
        if let first = firstClap, time - first > 0.9 { firstClap = nil }
        let isPulse = peak >= threshold && peak > max(rms * 2.2, 0.08)
        if isPulse {
            if pulseStart == nil { pulseStart = time }
            return false
        }
        guard let start = pulseStart else { return false }
        pulseStart = nil
        let duration = time - start
        guard duration >= 0.002, duration <= 0.14 else { firstClap = nil; return false }
        if let first = firstClap {
            let gap = start - first
            if gap >= 0.18 && gap <= 0.85 {
                firstClap = nil; cooldownUntil = time + 4
                return true
            }
            if gap < 0.18 { return false } // one clap's echo
        }
        firstClap = start
        return false
    }
}

enum JarvisError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

enum LocalModelPolicy {
    static let allowed = ["qwen3.5:0.8b", "qwen3.5:2b"]
    static func validate(name: String, metadata: [String: Any]) throws {
        guard allowed.contains(name), metadata["remote_host"] == nil, metadata["remote_model"] == nil,
              let details = metadata["details"] as? [String: Any], details["format"] as? String == "gguf" else {
            throw JarvisError.message("Only a verified local Qwen model is permitted. Cloud models are disabled.")
        }
    }
}

enum ContentBudget {
    static let sourceLimit = 6000
    static func excerpt(_ text: String) -> (text: String, truncated: Bool) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(clean.prefix(sourceLimit)), clean.count > sourceLimit)
    }
}

enum BrowserPolicy {
    static func allowed(_ destination: String, from origin: String) -> Bool {
        guard let url = URL(string: destination), let base = URL(string: origin),
              url.scheme == "https", url.host == base.host, url.user == nil, url.password == nil else { return false }
        let path = (url.path + "?" + (url.query ?? "")).lowercased()
        return !["logout", "signout", "delete", "unsubscribe", "checkout", "purchase", "remove", "submit"].contains(where: path.contains)
    }
}

enum WakePhrase {
    /// Require a leading wake phrase; mentioning Jarvis inside other speech cannot run a command.
    static func command(in transcript: String, followUp: Bool = false) -> String? {
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "^(?:(?:hey|hi|okay|ok)[, ]+)?jarvis\\b[,.:!? ]*"
        guard let range = clean.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return followUp ? clean : nil
        }
        return String(clean[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A lightweight speech gate. Only speech-like segments reach local transcription.
struct VoiceActivityDetector {
    enum Event { case none, start, finish, discard }
    private var noiseFloor: Float = 0.003
    private var candidateDuration: Double = 0
    private var segmentDuration: Double = 0
    private var voicedDuration: Double = 0
    private var quietDuration: Double = 0
    private(set) var active = false

    mutating func feed(rms: Float, duration: Double) -> Event {
        let voiced = rms >= max(0.012, noiseFloor * 3)
        if !active {
            if !voiced { noiseFloor = min(0.015, noiseFloor * 0.99 + rms * 0.01) }
            candidateDuration = voiced ? candidateDuration + duration : 0
            guard candidateDuration >= 0.09 else { return .none }
            active = true; segmentDuration = candidateDuration; voicedDuration = candidateDuration; quietDuration = 0
            return .start
        }
        segmentDuration += duration
        if voiced { voicedDuration += duration; quietDuration = 0 } else { quietDuration += duration }
        guard quietDuration >= 0.85 || segmentDuration >= 12 else { return .none }
        // Never execute a command cut off by the duration cap, especially a message body.
        let accepted = voicedDuration >= 0.22 && quietDuration >= 0.85
        active = false; candidateDuration = 0
        return accepted ? .finish : .discard
    }
}
