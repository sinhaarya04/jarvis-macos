import Foundation

enum InstagramCommand: Equatable {
    case profile(String)
    case choose(String)
    case message(recipient: String?, body: String?, send: Bool)
    case sendDraft
}

enum InstagramIntent {
    static func parse(_ text: String) -> InstagramCommand? {
        func match(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                  let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? "" }
        }
        let site = "(?:instagram|insta(?:gram)?|instgram|instgaram)"
        if let m = match("^(?:open|find|search(?: for)?|look up|go to)(?: the)? (.+?)(?:'s profile| profile)? (?:on|in) \(site)[.!?]?$") { return .profile(m[0]) }
        if let m = match("^(?:open|find) \(site)(?: profile (?:for )?| for )(.+?)[!?]?$") { return .profile(m[0]) }
        if let m = match("^(?:choose|select|the|open) (first|second|third|fourth|fifth|[1-5])(?: one| account| profile)?[.!?]?$") { return .choose(m[0]) }
        if let m = match("^(?:choose|select)(?: account)? (@?[A-Za-z0-9_.]{1,30})[!?]?$") { return .choose(m[0]) }
        let clean = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!? "))
        if ["send it", "send that", "send the message", "send this message"].contains(clean) { return .sendDraft }
        // Require Instagram explicitly for named recipients. Pronouns resolve only within a live Instagram context.
        if let m = match("^(send|draft|write)(?: an?| the)? (?:instagram )?message to (.+?) on \(site)(?::\\s*| saying\\s+)(.+)$") {
            return .message(recipient: m[1], body: m[2], send: m[0].lowercased() == "send")
        }
        if let m = match("^(send|draft|write)(?: an?| the)? instagram message to (.+?)(?::\\s*| saying\\s+)(.+)$") {
            return .message(recipient: m[1], body: m[2], send: m[0].lowercased() == "send")
        }
        if let m = match("^(message|dm) (.+?) on \(site)(?::\\s*| saying\\s+)(.+)$") {
            return .message(recipient: m[1], body: m[2], send: true)
        }
        if let m = match("^(send|draft|write)(?: (?:her|him|them))?(?: an?| the)? message(?::\\s*| saying\\s+)(.+)$") {
            return .message(recipient: nil, body: m[1], send: m[0].lowercased() == "send")
        }
        if let m = match("^(?:message|dm) (?:her|him|them)(?::\\s*| saying\\s+)(.+)$") { return .message(recipient: nil, body: m[0], send: true) }
        if ["message her", "message him", "message them", "send her a message", "send him a message", "send them a message", "give her a message", "give him a message", "draft a message", "write a message"].contains(clean) {
            return .message(recipient: nil, body: nil, send: false)
        }
        return nil
    }
}

struct InstagramProfile: Codable, Equatable {
    let handle: String
    let label: String
    var url: String { "https://www.instagram.com/\(handle)/" }
}

enum InstagramPolicy {
    static func handle(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "^@", with: "", options: .regularExpression)
        guard value.range(of: "^[a-z0-9_][a-z0-9_.]{0,29}$", options: .regularExpression) != nil,
              !value.hasSuffix("."), !value.contains("..") else { return nil }
        return value
    }
    static func profileHandle(url: String) -> String? {
        guard let u = URL(string: url), u.scheme == "https", ["www.instagram.com", "instagram.com"].contains(u.host ?? ""),
              u.user == nil, u.password == nil, u.query == nil else { return nil }
        let parts = u.path.split(separator: "/")
        guard parts.count == 1, !["direct", "explore", "accounts", "reels", "p", "stories", "legal", "about"].contains(String(parts[0])) else { return nil }
        return handle(String(parts[0]))
    }
    static func nameKey(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }
    static func matches(_ profile: InstagramProfile, query: String) -> Bool {
        let key = nameKey(query)
        return !key.isEmpty && (nameKey(profile.handle).contains(key) || nameKey(profile.label).contains(key))
    }
    static func choice(_ phrase: String, from choices: [InstagramProfile]) -> InstagramProfile? {
        let word = phrase.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
            .replacingOccurrences(of: "^(?:the )|(?: one| account| profile)$", with: "", options: .regularExpression)
        let numbers = ["first": 0, "1": 0, "second": 1, "2": 1, "third": 2, "3": 2, "fourth": 3, "4": 3, "fifth": 4, "5": 4]
        if let index = numbers[word], choices.indices.contains(index) { return choices[index] }
        let spoken = word.replacingOccurrences(of: " dot ", with: ".").replacingOccurrences(of: " underscore ", with: "_")
        guard let h = handle(spoken) else { return nil }
        return choices.first { $0.handle == h }
    }
}
