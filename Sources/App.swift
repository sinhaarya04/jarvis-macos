import AppKit
import SwiftUI
import Carbon
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private var model: AppModel!
    private var commandHUD: CommandHUD?
    private var hotkeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var observation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        model.onTypeRequested = { [weak self] in self?.typeCommand() }
        commandHUD = CommandHUD(model: model)
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--remember-instagram"), arguments.indices.contains(index + 2) {
            model.instagram.remember(name: arguments[index + 1], handle: arguments[index + 2])
        }
        if arguments.contains("--direct-listening") { model.directListening = true }
        if let index = arguments.firstIndex(of: "--import-claude-from"), arguments.indices.contains(index + 1) {
            do {
                try ClaudeCredentials.importEnvironmentFile(arguments[index + 1])
                model.selectedModel = "claude-sonnet-4-6"
                AudioLog.logger.notice("Claude key imported to Keychain; Sonnet selected")
                Task { await model.refreshModel(); await model.model.unload("qwen3.5:0.8b") }
            } catch { model.append(error.localizedDescription) }
        }
        if let index = arguments.firstIndex(of: "--import-typesafe-from"), arguments.indices.contains(index + 1) {
            do {
                let path = arguments[index + 1]
                try JevCredentials.save(String(contentsOfFile: path, encoding: .utf8))
                try FileManager.default.removeItem(atPath: path)
                model.jevEnabled = true
                AudioLog.logger.notice("TypeSafe key imported to Keychain; Jev enabled")
                Task { await model.refreshModel() }
            } catch { model.append(error.localizedDescription) }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        statusItem.menu = menu
        observation = Publishers.CombineLatest4(model.$recording, model.$busy, model.$status, model.$listening)
            .sink { [weak self] recording, busy, status, listening in
                Task { @MainActor in
                    let symbol = recording ? "mic.fill" : busy ? "ellipsis.circle" : listening ? "mic.circle" : "waveform.circle"
                    self?.statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "JARVIS: \(status)")
                    self?.statusItem.button?.toolTip = "JARVIS · \(status)\n⌥ Space: talk · ⌥ Esc: stop"
                }
            }
        registerHotkeys()
        if ProcessInfo.processInfo.arguments.contains("--listen") { model.setListening(true) }
        if ProcessInfo.processInfo.arguments.contains("--test-greeting") { model.submit("test greeting") }
        if arguments.contains("--preview-command-bar") {
            model.transcript = "Jarvis, can you open the Notes app?"
            model.status = "Command bar preview"
        }
        if arguments.contains("--check-connected-services") {
            Task { await model.checkConnectedServices() }
        }
        if arguments.contains("--show-command-input") {
            // Only an explicit development/manual-input launch needs a foreground app window.
            NSApp.setActivationPolicy(.regular)
            Task { @MainActor in self.typeCommand() }
        }
        // No window or app activation at launch. Diagnostic audio requires an explicit flag.
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.actions.rememberFrontmost()
        menu.removeAllItems()
        let status = NSMenuItem(title: model.status, action: nil, keyEquivalent: "")
        status.isEnabled = false; menu.addItem(status); menu.addItem(.separator())
        let talkItem = add(model.recording ? "Finish recording" : "Talk to JARVIS", #selector(talk), to: menu)
        talkItem.isEnabled = !model.busy
        talkItem.keyEquivalent = " "; talkItem.keyEquivalentModifierMask = .option
        let stopItem = add("Stop", #selector(stop), to: menu)
        stopItem.keyEquivalent = "\u{1b}"; stopItem.keyEquivalentModifierMask = .option
        let listeningItem = add("JARVIS listening", #selector(toggleListening), to: menu)
        listeningItem.state = model.handsFreeEnabled && model.clapsEnabled ? .on : model.handsFreeEnabled || model.clapsEnabled ? .mixed : .off
        if model.clapsEnabled {
            let rearm = add(model.clapStatus, #selector(rearmClaps), to: menu)
            rearm.isEnabled = false
        }
        add("Office mode", #selector(office), to: menu).isEnabled = !model.busy && !model.recording
        menu.addItem(.separator())
        add("Type a command…", #selector(typeCommand), to: menu).isEnabled = !model.busy && !model.recording
        add("Read last response", #selector(readLastResponse), to: menu).isEnabled = !model.busy && !model.recording
        add("Test greeting", #selector(testGreeting), to: menu).isEnabled = !model.busy && !model.recording
        add("Copy last response", #selector(copyLastResponse), to: menu)
        if !model.recipients.isEmpty {
            let pending = NSMenuItem(title: "Send pending message to", action: nil, keyEquivalent: "")
            let choices = NSMenu(); choices.autoenablesItems = false
            let body = NSMenuItem(title: model.pendingMessage, action: nil, keyEquivalent: "")
            body.isEnabled = false; body.toolTip = model.pendingMessage
            choices.addItem(body); choices.addItem(.separator())
            for recipient in model.recipients {
                let choice = add("\(recipient.name) · \(recipient.handle)", #selector(sendSelected(_:)), to: choices)
                choice.representedObject = recipient.id.uuidString
            }
            pending.submenu = choices; menu.addItem(pending)
        }
        menu.addItem(.separator())
        add("Settings…", #selector(settings), to: menu)
        add("What can I say?", #selector(help), to: menu).isEnabled = !model.busy && !model.recording
        add("Quit JARVIS", #selector(quit), to: menu)
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; menu.addItem(item); return item
    }

    private func registerHotkeys() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let pointer, let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(pointer).takeUnretainedValue()
            let id = identifier.id
            Task { @MainActor in if id == 2 { delegate.stop() } else { delegate.talk() } }
            return noErr
        }, 1, &type, context, &handler)
        for (key, id) in [(kVK_Space, UInt32(1)), (kVK_Escape, UInt32(2))] {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(key), UInt32(optionKey), EventHotKeyID(signature: 0x4A525653, id: id), GetApplicationEventTarget(), 0, &reference)
            if result == noErr, let reference { hotkeys.append(reference) }
            else { model.append("A JARVIS shortcut is already in use. Talk and Stop are also available in the menu bar.") }
        }
    }

    @objc func settings() {
        model.actions.rememberFrontmost()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 690), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "JARVIS Settings"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model, mail: model.mail, close: { [weak self] in self?.settingsWindow?.close() }))
            window.center(); settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func typeCommand() {
        guard !model.busy, !model.recording else { return }
        model.actions.rememberFrontmost()
        model.prepareTypedCommand()
        defer { model.resumeClaps() }
        let alert = NSAlert()
        alert.messageText = "Tell JARVIS what to do"
        alert.informativeText = "You can also use ⌥ Space from any app."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 26))
        input.placeholderString = "Open Claude in Chrome"; alert.accessoryView = input
        alert.addButton(withTitle: "Run"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        NSApp.activate(ignoringOtherApps: true)
        let result = alert.runModal()
        NSApp.setActivationPolicy(.accessory)
        _ = model.actions.target?.activate(options: [])
        if result == .alertFirstButtonReturn { model.submit(input.stringValue) }
    }
    @objc func talk() { model.toggleRecording() }
    @objc func office() { model.actions.rememberFrontmost(); model.submit("Office mode") }
    @objc func toggleClaps() { model.setClaps(!model.clapsEnabled) }
    @objc func toggleListening() { model.setListening(!(model.handsFreeEnabled || model.clapsEnabled)) }
    @objc func toggleHandsFree() { model.setHandsFree(!model.handsFreeEnabled) }
    @objc func rearmClaps() { model.setClaps(true) }
    @objc func readLastResponse() { model.readLastResponse() }
    @objc func testGreeting() { model.submit("test greeting") }
    @objc func copyLastResponse() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.lastResponse, forType: .string)
    }
    @objc func sendSelected(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let recipient = model.recipients.first(where: { $0.id.uuidString == id }) else { return }
        model.sendSelected(recipient)
    }
    @objc func help() { model.submit("Help") }
    @objc func stop() { model.stop() }
    @objc func quit() { model.stop(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        for hotkey in hotkeys { UnregisterEventHotKey(hotkey) }
        if let handler { RemoveEventHandler(handler) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { false }
}

@main
struct JarvisMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate(); app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
