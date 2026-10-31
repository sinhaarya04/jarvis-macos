import Foundation

struct InstagramTab { let windowID: Int; let tabID: String }
struct InstagramControl: Codable {
    let id: Int; let kind: String; let label: String; let value: String; let href: String; let recipient: String
}
struct InstagramSnapshot: Codable {
    let url: String; let nonce: String; let controls: [InstagramControl]; let profile: String
    let loginRequired: Bool; let searchValue: String
    var profiles: [InstagramProfile] {
        var seen = Set<String>()
        return controls.filter { $0.kind == "profile" && InstagramPolicy.profileHandle(url: $0.href) == $0.recipient && seen.insert($0.recipient).inserted }
            .map { InstagramProfile(handle: $0.recipient, label: $0.label) }
    }
}

extension MacActions {
    func instagramTab() async throws -> InstagramTab {
        let raw = try await script("""
        tell application "Google Chrome"
            if count of windows is 0 then make new window
            -- Keep IDs, not loop references: "w" means "item k of windows" and moves once the window order changes.
            set windowID to id of front window
            set tabID to missing value
            repeat with w in windows
                repeat with t in tabs of w
                    if URL of t starts with "https://www.instagram.com/" or URL of t starts with "https://instagram.com/" then
                        set windowID to id of w
                        set tabID to id of t
                        exit repeat
                    end if
                end repeat
                if tabID is not missing value then exit repeat
            end repeat
            set chosenWindow to window id windowID
            if tabID is missing value then set tabID to id of (make new tab at end of tabs of chosenWindow with properties {URL:"https://www.instagram.com/"})
            repeat with i from 1 to count of tabs of chosenWindow
                if id of tab i of chosenWindow is tabID then set active tab index of chosenWindow to i
            end repeat
            set index of chosenWindow to 1
            activate
            return (windowID as text) & linefeed & (tabID as text)
        end tell
        """)
        let parts = raw.components(separatedBy: "\n")
        guard parts.count == 2, let id = Int(parts[0]) else { throw JarvisError.message("Chrome did not identify the Instagram tab.") }
        return InstagramTab(windowID: id, tabID: parts[1])
    }
    func instagramNavigate(_ profile: InstagramProfile, tab: InstagramTab) async throws {
        guard InstagramPolicy.profileHandle(url: profile.url) == profile.handle else { throw JarvisError.message("Invalid Instagram handle.") }
        _ = try await script("""
        on run argv
            tell application "Google Chrome"
                set t to tab id (item 2 of argv) of window id ((item 1 of argv) as integer)
                if URL of t does not start with "https://www.instagram.com/" and URL of t does not start with "https://instagram.com/" then error "The Instagram tab moved to another website."
                set URL of t to item 3 of argv
            end tell
        end run
        """, args: [String(tab.windowID), tab.tabID, profile.url])
    }
    private func instagramJavaScript(_ request: [String: Any], tab: InstagramTab) async throws -> Data {
        guard let resource = Bundle.main.url(forResource: "instagram-controls", withExtension: "js") else { throw JarvisError.message("The Instagram browser adapter is missing. Reinstall JARVIS.") }
        let source = try String(contentsOf: resource, encoding: .utf8)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]), as: UTF8.self)
        let javascript = "(() => { " + source + "\n; try { return JSON.stringify(jarvisInstagram(" + json + ")); } catch(e) { return JSON.stringify({error:String(e.message)}); } })()"
        let raw = try await script("""
        on run argv
            tell application "Google Chrome"
                set t to tab id (item 2 of argv) of window id ((item 1 of argv) as integer)
                return execute t javascript (item 3 of argv)
            end tell
        end run
        """, args: [String(tab.windowID), tab.tabID, javascript])
        let data = Data(raw.utf8)
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let message = object["error"] as? String {
            throw JarvisError.message(String(message.prefix(300)))
        }
        return data
    }
    func instagramSnapshot(tab: InstagramTab) async throws -> InstagramSnapshot {
        try Task.checkCancellation()
        let data = try await instagramJavaScript(["mode":"snapshot"], tab: tab)
        let page = try JSONDecoder().decode(InstagramSnapshot.self, from: data)
        guard !page.loginRequired else { throw JarvisError.message("Sign into Instagram in Chrome, then repeat your command.") }
        return page
    }
    func instagramAct(_ control: InstagramControl, page: InstagramSnapshot, tab: InstagramTab, text: String = "", recipient: String = "", send: Bool = false) async throws {
        try Task.checkCancellation()
        guard page.controls.contains(where: { $0.id == control.id && $0.kind == control.kind }) else { throw JarvisError.message("That control is no longer available.") }
        let operation = ["searchField","composer"].contains(control.kind) ? "fill" : "click"
        _ = try await instagramJavaScript(["mode":"action", "operation":operation, "id":control.id, "nonce":page.nonce,
            "url":page.url, "text":text, "recipient":recipient, "allowSend":send], tab:tab)
    }
}

/// Short-lived conversation context, separate from the browser's untrusted page text.
@MainActor
final class InstagramAssistant {
    private let actions: MacActions
    private let jev: JevModel
    private var tab: InstagramTab?
    private(set) var profile: InstagramProfile?
    private var choices: [InstagramProfile] = []
    private var query = ""
    private var expires = Date.distantPast
    private var draft: String?
    private var awaitingBody = false
    private var deferredMessage: (String?, Bool)?
    private var aliases: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "instagramAliases") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "instagramAliases") }
    }
    init(actions: MacActions, jev: JevModel) { self.actions = actions; self.jev = jev }
    func remember(name: String, handle: String) {
        guard let h = InstagramPolicy.handle(handle) else { return }
        aliases[InstagramPolicy.nameKey(name)] = h
    }
    func cancel() { draft = nil; awaitingBody = false; deferredMessage = nil; choices = []; profile = nil; expires = .distantPast }
    func followUp(_ text: String) -> InstagramCommand? {
        guard expires > Date() else { return nil }
        let stripped = WakePhrase.command(in: text, followUp: true) ?? text
        if !choices.isEmpty, let choice = InstagramPolicy.choice(stripped, from: choices) { return .choose(choice.handle) }
        if awaitingBody, let range = stripped.range(of: "^(?:say|saying|tell her|tell him|tell them)\\s+", options: [.regularExpression,.caseInsensitive]) {
            return .message(recipient: nil, body: String(stripped[range.upperBound...]), send: true)
        }
        return nil
    }
    private func select(_ kind: String, page: InstagramSnapshot, recipient: String = "") async throws -> InstagramControl {
        let candidates = page.controls.filter { $0.kind == kind && (recipient.isEmpty || $0.recipient == recipient) }
        guard !candidates.isEmpty else { throw JarvisError.message("Instagram isn't showing the \(kind == "composer" ? "message box for this person" : kind + " control"). Open the relevant panel and retry.") }
        // Jev chooses from compatible observed controls; it cannot select a different operation or recipient.
        let id = try await jev.chooseInstagramControl(kind: kind, controls: candidates)
        guard let control = candidates.first(where: { $0.id == id }) else { throw JarvisError.message("Jev could not select a visible Instagram control.") }
        return control
    }
    private func observeUntil(_ tab: InstagramTab, predicate: (InstagramSnapshot) -> Bool) async throws -> InstagramSnapshot {
        for _ in 0..<24 {
            try Task.checkCancellation()
            let page = try await actions.instagramSnapshot(tab: tab)
            if predicate(page) { return page }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw JarvisError.message("Instagram hasn't finished loading the expected page. Please retry.")
    }
    func run(_ command: InstagramCommand) async throws -> String {
        switch command {
        case .profile(let name): return try await find(name)
        case .choose(let answer):
            guard expires > Date(), let selected = InstagramPolicy.choice(answer, from: choices), let tab else {
                throw JarvisError.message("Search for someone on Instagram first, then choose one of the listed accounts.")
            }
            remember(name: query, handle: selected.handle)
            choices = []
            let pending = deferredMessage; deferredMessage = nil
            let result = try await open(selected, tab: tab)
            if let pending { return result + " " + (try await message(body: pending.0, send: pending.1)) }
            return result
        case .message(let recipient, let body, let send):
            if let recipient {
                let result = try await find(recipient)
                if !choices.isEmpty { deferredMessage = (body, send); return result }
            }
            return try await message(body: body, send: send)
        case .sendDraft:
            guard let body = draft, !body.isEmpty else { throw JarvisError.message("There isn't a prepared Instagram message to send.") }
            return try await sendPrepared(body)
        }
    }
    private func find(_ name: String) async throws -> String {
        guard !name.isEmpty, name.count <= 100 else { throw JarvisError.message("Say a person's name or Instagram handle.") }
        cancel(); query = name
        let tab = try await actions.instagramTab(); self.tab = tab
        expires = Date().addingTimeInterval(300)
        // An explicit @handle wins over a remembered name: "@jordanlee" and "Jordan Lee" share a name key.
        let explicit = name.hasPrefix("@") ? InstagramPolicy.handle(name) : nil
        if let known = explicit ?? aliases[InstagramPolicy.nameKey(name)] {
            return try await open(InstagramProfile(handle: known, label: name), tab: tab)
        }
        var page = try await observeUntil(tab) { $0.controls.contains { $0.kind == "search" || $0.kind == "searchField" } }
        if !page.controls.contains(where: { $0.kind == "searchField" }) {
            let control = try await select("search", page: page)
            try await actions.instagramAct(control, page:page, tab:tab)
            page = try await observeUntil(tab) { $0.controls.contains { $0.kind == "searchField" } }
        }
        let field = try await select("searchField", page:page)
        try await actions.instagramAct(field, page:page, tab:tab, text:name)
        // Wait for new results, never choose rows left over from a previous query.
        try await Task.sleep(nanoseconds: 900_000_000)
        page = try await observeUntil(tab) { $0.searchValue == name && $0.profiles.contains { InstagramPolicy.matches($0,query:name) } }
        choices = Array(page.profiles.filter { InstagramPolicy.matches($0,query:name) }.prefix(5))
        if choices.count == 1 { let result = choices[0]; choices = []; return try await open(result, tab:tab) }
        return "I found several accounts. " + choices.enumerated().map { "\($0.offset + 1): @\($0.element.handle)" }.joined(separator: ". ") + ". Say the number or the handle."
    }
    private func open(_ selected: InstagramProfile, tab: InstagramTab) async throws -> String {
        try await actions.instagramNavigate(selected, tab:tab)
        _ = try await observeUntil(tab) { $0.profile == selected.handle }
        profile = selected; expires = Date().addingTimeInterval(300); draft = nil
        return "Opened @\(selected.handle) on Instagram."
    }
    private func composer() async throws -> (InstagramTab, InstagramSnapshot, InstagramControl) {
        guard expires > Date(), let profile, let tab else { throw JarvisError.message("Open the person's Instagram profile first so I know who you mean.") }
        var page = try await actions.instagramSnapshot(tab:tab)
        if !page.controls.contains(where: { $0.kind == "composer" && $0.recipient == profile.handle }) {
            guard page.profile == profile.handle else { throw JarvisError.message("The Instagram profile changed. Say who to message again.") }
            let button = try await select("message", page:page)
            try await actions.instagramAct(button, page:page, tab:tab, recipient:profile.handle)
            page = try await observeUntil(tab) { $0.controls.contains { $0.kind == "composer" && $0.recipient == profile.handle } }
        }
        return (tab,page,try await select("composer",page:page,recipient:profile.handle))
    }
    private func message(body: String?, send: Bool) async throws -> String {
        guard expires > Date(), let profile else { throw JarvisError.message("Open the person's Instagram profile first so I know who you mean.") }
        guard let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            awaitingBody = true; expires = Date().addingTimeInterval(300)
            return "What should I say to @\(profile.handle)? Say, for example, message her saying, followed by your message."
        }
        guard body.count <= 2000 else { throw JarvisError.message("Keep this Instagram message under 2,000 characters.") }
        awaitingBody = false; draft = nil
        let (tab,page,editor) = try await composer()
        guard editor.value.isEmpty else { throw JarvisError.message("There's already text in @\(profile.handle)'s message box. Review it first; I haven't replaced it.") }
        try await actions.instagramAct(editor,page:page,tab:tab,text:body,recipient:profile.handle)
        _ = try await observeUntil(tab) { $0.controls.contains { $0.kind == "composer" && $0.recipient == profile.handle && $0.value == body } }
        draft = body; expires = Date().addingTimeInterval(300)
        if send { return try await sendPrepared(body) }
        return "Draft ready for @\(profile.handle): \(body). Say send it when ready."
    }
    private func sendPrepared(_ body: String) async throws -> String {
        guard expires > Date(), let profile, let tab else { throw JarvisError.message("That Instagram message context expired. Say who to message again.") }
        let page = try await actions.instagramSnapshot(tab:tab)
        guard page.controls.contains(where: { $0.kind == "composer" && $0.recipient == profile.handle && $0.value == body }) else {
            draft = nil; throw JarvisError.message("The recipient or draft changed. Nothing was sent.")
        }
        let button = try await select("send",page:page,recipient:profile.handle)
        draft = nil // A timeout must never make the same submission automatically available for retry.
        do {
            try await actions.instagramAct(button,page:page,tab:tab,text:body,recipient:profile.handle,send:true)
            _ = try await observeUntil(tab) { $0.controls.contains { $0.kind == "composer" && $0.recipient == profile.handle && $0.value.isEmpty } }
        } catch { throw JarvisError.message("I couldn't verify the send result. Check the Instagram chat before retrying.") }
        return "Submitted your message to @\(profile.handle). Delivery isn't verified."
    }
}
