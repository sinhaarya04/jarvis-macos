import AppKit
import ApplicationServices
import Contacts

struct PageContent { let title: String; let url: String; let text: String }

@MainActor
final class MacActions {
    var target: NSRunningApplication?
    private var observer: NSObjectProtocol?
    init() {
        rememberFrontmost()
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            Task { @MainActor in self?.target = app }
        }
    }
    func rememberFrontmost() {
        if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier { target = app }
    }
    func open(_ name: String) async throws -> String {
        let query = OpenTargetPolicy.normalize(name)
        if let address = OpenTargetPolicy.website(name) {
            guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else { throw JarvisError.message("Google Chrome is not installed.") }
            _ = try await NSWorkspace.shared.open([address], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
            return "Opened \(name) in Chrome."
        }
        let aliases = OpenTargetPolicy.applications
        if query == "outlook", NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.Outlook") == nil { return try await open("outlook web") }
        var url = aliases[query].flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        if url == nil {
            let roots = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
            let matches = roots.flatMap { root -> [URL] in
                ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" && $0.deletingPathExtension().lastPathComponent.lowercased() == query }
            }
            guard matches.count == 1 else { throw JarvisError.message("I couldn't find \(name). If it's a website, say its name or domain, such as Instagram or instagram.com.") }
            url = matches[0]
        }
        guard let url else { throw JarvisError.message("That application is not installed.") }
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return "Opened \(url.deletingPathExtension().lastPathComponent)."
    }

    func script(_ source: String, args: [String] = []) async throws -> String {
        try await ProcessRunner.run("/usr/bin/osascript", ["-e", source, "--"] + args)
    }
    func search(_ query: String) async throws -> String {
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else { throw JarvisError.message("Google Chrome is not installed.") }
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: String(query.prefix(1500)))]
        guard let url = components.url else { throw JarvisError.message("That search could not be opened.") }
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
        return "Searching Google for \(query)."
    }
    func switchTab(_ query: String) async throws -> String {
        try await script("""
        on run argv
            set needle to item 1 of argv
            tell application "Google Chrome"
                set matches to {}
                repeat with w in windows
                    repeat with i from 1 to count of tabs of w
                        set t to tab i of w
                        ignoring case
                            if title of t contains needle or URL of t contains needle then set end of matches to {id of w, i}
                        end ignoring
                    end repeat
                end repeat
                if count of matches is 0 then error "No matching Chrome tab."
                if count of matches is greater than 1 then error "Several tabs match. Use a more specific title."
                set chosen to item 1 of matches
                set w to window id (item 1 of chosen)
                set active tab index of w to item 2 of chosen
                set index of w to 1
                activate
                return "Switched to " & title of active tab of w
            end tell
        end run
        """, args: [query])
    }
    func note(title: String, body: String) async throws -> String {
        let escaped = body.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>")
        let heading = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        _ = try await script("""
        on run argv
            tell application "Notes"
                set newNote to make new note at default account with properties {name:item 1 of argv, body:item 2 of argv}
                if not (exists newNote) then error "The note was not created."
                show newNote
                return id of newNote
            end tell
        end run
        """, args: [title, "<h1>\(heading)</h1><div>\(escaped)</div>"])
        return "Created the note ‘\(title)’."
    }

    func selectedText() throws -> String {
        guard AXIsProcessTrusted() else { throw JarvisError.message("Enable JARVIS in System Settings → Privacy & Security → Accessibility to read selected text or type.") }
        guard let target, !target.isTerminated else { throw JarvisError.message("Select text in another app, then open JARVIS.") }
        let app = AXUIElementCreateApplication(target.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused else { throw JarvisError.message("No text field is selected in \(target.localizedName ?? "the previous app").") }
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &value)
        guard let text = value as? String, !text.isEmpty else { throw JarvisError.message("Select the email or text you want summarized, then try again.") }
        return text
    }

    func type(_ text: String) async throws -> String {
        guard AXIsProcessTrusted() else { throw JarvisError.message("Enable JARVIS in Privacy & Security → Accessibility to type into other apps.") }
        guard let app = target, !app.isTerminated else { throw JarvisError.message("Focus a text field in another app first.") }
        guard app.activate(options: []) else { throw JarvisError.message("Could not focus the target app.") }
        try await Task.sleep(nanoseconds: 250_000_000)
        try Task.checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { throw JarvisError.message("Focus changed. Text was not inserted.") }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused else { throw JarvisError.message("Click an editable text field first.") }
        let ax = focused as! AXUIElement
        var editable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(ax, kAXValueAttribute as CFString, &editable)
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(ax, kAXRoleAttribute as CFString, &role)
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(ax, kAXSubroleAttribute as CFString, &subrole)
        guard subrole as? String != kAXSecureTextFieldSubrole else { throw JarvisError.message("Dictation is unavailable in password fields.") }
        guard editable.boolValue || [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role as? String ?? "") else { throw JarvisError.message("The focused element does not look editable. Click the text field and retry.") }
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } } ?? []
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
        let writtenCount = pasteboard.changeCount
        defer {
            if pasteboard.changeCount == writtenCount {
                pasteboard.clearContents()
                let items = saved.map { values -> NSPasteboardItem in let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item }
                pasteboard.writeObjects(items)
            }
        }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down)
            event?.flags = .maskCommand; event?.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(nanoseconds: 600_000_000)
        return "Pasted into \(app.localizedName ?? "the selected app")."
    }

    func currentPage() async throws -> PageContent {
        let raw = try await script("""
        tell application "Google Chrome"
            if count of windows is 0 then error "Open a page in Chrome first."
            return execute active tab of front window javascript "JSON.stringify({title:document.title,url:location.href,text:(window.getSelection().toString()||(document.querySelector('article')||document.body).innerText).slice(0,18000)})"
        end tell
        """)
        guard let data = raw.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: String], let text = object["text"], !text.isEmpty else { throw JarvisError.message("Chrome did not return readable page text.") }
        return PageContent(title: object["title"] ?? "Page", url: object["url"] ?? "", text: text)
    }

    func recipients(_ name: String) async throws -> [MessageRecipient] {
        if name.range(of: "^\\+?[0-9() .-]{7,}$", options: .regularExpression) != nil || name.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) != nil {
            return [MessageRecipient(name: name, handle: name, requiresConfirmation: false)]
        }
        let store = CNContactStore()
        guard try await store.requestAccess(for: .contacts) else { throw JarvisError.message("Contacts access is needed to resolve that name. You can also specify a phone number or email.") }
        let contacts = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: [CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor])
        let matches = contacts.flatMap { contact -> [MessageRecipient] in
            let full = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
            let exact = MessageRecipient.isExactName(name, givenName: contact.givenName, familyName: contact.familyName)
            let handles = contact.phoneNumbers.map { $0.value.stringValue } + contact.emailAddresses.map { $0.value as String }
            return Array(Set(handles)).sorted().map { MessageRecipient(name: full, handle: $0, requiresConfirmation: !exact) }
        }
        guard !matches.isEmpty else { throw JarvisError.message("No contact address matched \(name).") }
        return matches
    }

    func send(to recipient: MessageRecipient, text: String) async throws -> String {
        _ = try await script("""
        on run argv
            tell application "Messages"
                set accountsFound to accounts whose service type is iMessage
                if count of accountsFound is 0 then error "Sign into iMessage in Messages first."
                set destination to participant (item 1 of argv) of item 1 of accountsFound
                send (item 2 of argv) to destination
                return "submitted"
            end tell
        end run
        """, args: [recipient.handle, text])
        return "Submitted your iMessage to \(recipient.name). Delivery has not been verified."
    }
}
