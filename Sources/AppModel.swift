import AppKit
import SwiftUI
import ApplicationServices

struct ConversationEntry: Identifiable {
    let id = UUID()
    let user: Bool
    var text: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published var entries = [ConversationEntry(user: false, text: "At your service. Turn on JARVIS listening and say Jarvis, followed by your command.")]
    @Published var transcript = ""
    @Published var directListening = UserDefaults.standard.bool(forKey: "directListening") {
        didSet {
            UserDefaults.standard.set(directListening, forKey: "directListening")
            if listening { status = directListening ? "Listening · speak a command" : "Listening for Jarvis" }
        }
    }
    @Published var jevEnabled = UserDefaults.standard.bool(forKey: "jevEnabled") {
        didSet { UserDefaults.standard.set(jevEnabled, forKey: "jevEnabled") }
    }
    @Published var jevStatus = "TypeSafe key needed"
    @Published var busy = false
    @Published var recording = false
    @Published var status = "Ready when you are"
    @Published var modelStatus = "Checking local model…"
    @Published var modelReady = false
    @Published var selectedModel = UserDefaults.standard.string(forKey: "selectedModel") ?? "qwen3.5:0.8b" {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "selectedModel") }
    }
    @Published var speakReplies = UserDefaults.standard.object(forKey: "speakReplies") as? Bool ?? true {
        didSet { UserDefaults.standard.set(speakReplies, forKey: "speakReplies") }
    }
    @Published var handsFreeEnabled = false
    @Published var listening = false
    @Published var clapsEnabled = false
    @Published var clapsArmed = false
    var clapStatus: String { !clapsEnabled ? "Claps off" : !audio.isMonitoring || busy || voice.isSpeaking ? "Claps paused during speech or work" : clapsArmed ? "Claps listening" : "Claps cooling down" }
    @Published var memoryStatus = "On-demand memory"
    @Published var recipients: [MessageRecipient] = []
    @Published var pendingMessage = ""
    let mail = MicrosoftMail()
    let actions = MacActions()
    let audio = AudioInput()
    let voice = VoiceOutput()
    let model = LocalModel()
    let claude = ClaudeModel()
    let markets = MarketService()
    let jev = JevModel()
    lazy var instagram = InstagramAssistant(actions: actions, jev: jev)
    private var speechChunks = SpeechChunks()
    private var earlyOpenTask: Task<Void, Never>?
    private var liveCommandTask: Task<Void, Never>?
    var onTypeRequested: (() -> Void)?
    private var earlyOpenCandidate: String?
    private var earlyOpenedApp: String?
    private var earlyOpenedAt = Date.distantPast
    var usesClaude: Bool { ClaudeModel.allowed.contains(selectedModel) }
    private var waitingForCommandUntil: Date?
    private var listeningGeneration = UUID()
    private var currentInputIsVoice = false
    private var operation: Task<Void, Never>?
    private var recordTimer: Task<Void, Never>?
    private var clapRearmTask: Task<Void, Never>?
    private var memoryMonitor: DispatchSourceMemoryPressure?
    private var criticalMemory = false
    private var sleeping = false
    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        audio.livePreview.onText = { [weak self] text in
            guard let self, !self.busy, !self.voice.isSpeaking else { return }
            let followUp = self.directListening || (self.waitingForCommandUntil.map { $0 > Date() } ?? false)
            if WakePhrase.command(in: text, followUp: followUp) != nil {
                self.transcript = text
                self.status = "Hearing you…"
                self.scheduleEarlyOpen(self.directListening && WakePhrase.command(in: text) == nil ? "Jarvis, " + text : text)
                self.scheduleLiveCommand(text)
            }
        }
        audio.onClap = { [weak self] in
            guard let self else { return }
            guard self.clapsArmed, !self.busy, !self.voice.isSpeaking, self.sessionReady else {
                // The monitor stops reacting after one detected clap; restart it so later claps still count.
                self.pauseMonitoring(); self.resumeClaps(); return
            }
            AudioLog.logger.notice("Double clap accepted; starting Office mode")
            self.coolDownClaps()
            self.pauseMonitoring()
            self.submit("Office mode")
        }
        voice.onFinished = { [weak self] in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.resumeClaps()
            }
        }
        audio.onSpeech = { [weak self] file, liveText in self?.heardSpeech(file, liveText: liveText) }
        audio.onError = { [weak self] error in
            self?.setHandsFree(false)
            self?.announce("Microphone capture stopped. " + error.localizedDescription)
        }
        let monitor = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        monitor.setEventHandler { [weak self, weak monitor] in
            guard let self, let monitor else { return }
            self.criticalMemory = monitor.data.contains(.critical)
            self.memoryStatus = self.criticalMemory ? "Memory pressure · model paused" : monitor.data.contains(.warning) ? "Memory pressure · lightweight mode" : "On-demand memory"
            if self.criticalMemory && !self.usesClaude { self.stop() }
        }
        monitor.resume(); memoryMonitor = monitor
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.sleeping = true; self?.stop(); self?.pauseMonitoring() }
            })
        }
        let woke: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.sleeping = false
                if self?.clapsEnabled == true { self?.clapsArmed = true }
                self?.resumeClaps()
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main, using: woke))
        }
        // Locking the screen (Control-Command-Q) posts none of the workspace notifications above.
        let distributed = DistributedNotificationCenter.default()
        workspaceObservers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = true; self?.stop(); self?.pauseMonitoring() }
        })
        workspaceObservers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: woke))
        Task { await refreshModel() }
        if audio.hasPermission {
            handsFreeEnabled = UserDefaults.standard.bool(forKey: "handsFreeEnabled")
            clapsEnabled = UserDefaults.standard.bool(forKey: "clapsEnabled")
            clapsArmed = clapsEnabled
            resumeClaps()
        } else if UserDefaults.standard.bool(forKey: "clapsEnabled") || UserDefaults.standard.bool(forKey: "handsFreeEnabled") {
            status = "Microphone permission needed · enable listening in the menu"
            // A development rebuild can reset macOS permission. Restore only prior opt-ins.
            Task {
                guard await audio.permission() else { return }
                clapsEnabled = UserDefaults.standard.bool(forKey: "clapsEnabled")
                handsFreeEnabled = UserDefaults.standard.bool(forKey: "handsFreeEnabled")
                clapsArmed = clapsEnabled
                resumeClaps()
            }
        }
        AudioLog.logger.notice("JARVIS audio ready; microphone authorized: \(self.audio.hasPermission), claps enabled: \(self.clapsEnabled), spoken replies: \(self.speakReplies)")
    }

    var sessionReady: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return !sleeping && session?["CGSSessionScreenIsLocked"] as? Bool != true
    }

    /// Explicit installation diagnostic using synthetic prompts only; never runs the chosen action.
    func checkConnectedServices() async {
        var result: [String: Any] = ["checked_at": ISO8601DateFormatter().string(from: Date()), "model": selectedModel]
        do {
            let start = Date()
            let reply = try await claude.reply(to: "Can you hear me?", model: selectedModel, voiceInput: true, onToken: { _ in })
            result["claude_seconds"] = Date().timeIntervalSince(start)
            result["claude_reply"] = reply
        } catch { result["claude_error"] = error.localizedDescription }
        do {
            let start = Date()
            let command = try await jev.route("Could you bring up Notes for me?")
            result["jev_seconds"] = Date().timeIntervalSince(start)
            result["jev_open_notes_verified"] = command == .open("notes")
        } catch { result["jev_error"] = error.localizedDescription }
        result["on_device_live_speech_supported"] = audio.livePreview.supported
        result["on_device_live_speech_permitted"] = audio.livePreview.permitted
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/JARVIS")
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("service-check.json"), options: .atomic)
        }
        AudioLog.logger.notice("Connected-service diagnostic completed; no app action executed")
    }

    private func scheduleEarlyOpen(_ text: String) {
        let candidate = EarlyAppIntent.app(in: text)
        guard candidate != earlyOpenCandidate else { return }
        earlyOpenTask?.cancel(); earlyOpenCandidate = candidate
        guard let candidate, earlyOpenedApp == nil || Date().timeIntervalSince(earlyOpenedAt) > 15 else { return }
        earlyOpenTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, let self, self.handsFreeEnabled, self.sessionReady, !self.busy,
                  self.earlyOpenCandidate == candidate else { return }
            do {
                let result = try await self.actions.open(candidate)
                self.earlyOpenedApp = candidate; self.earlyOpenedAt = Date()
                self.status = "\(result) Keep speaking…"
                self.append(result)
            } catch { self.append("Early app opening did not complete. I'll use the finished command.") }
        }
    }

    private func scheduleLiveCommand(_ text: String) {
        liveCommandTask?.cancel()
        let followUp = directListening || (waitingForCommandUntil.map { $0 > Date() } ?? false)
        guard let words = WakePhrase.command(in: text, followUp: followUp), !words.isEmpty,
              CommandParser.parse(words).canUseLiveTranscript else { return }
        // A stable complete opening/search phrase need not wait for Whisper or the energy gate.
        // Writing, sending and other consequential actions still use a completed audio segment.
        liveCommandTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled, let self, self.handsFreeEnabled, self.sessionReady,
                  !self.busy, !self.recording, !self.voice.isSpeaking, self.transcript == text else { return }
            AudioLog.logger.notice("Hands-free stable live command accepted")
            self.submit(words, voiceInput: true)
        }
    }

    func refreshModel() async {
        jevStatus = (try? JevCredentials.read()) != nil ? "Jev connected · intent and link decisions" : "TypeSafe key needed"
        if usesClaude {
            modelReady = (try? ClaudeCredentials.read()) != nil
            modelStatus = modelReady ? (selectedModel.contains("haiku") ? "Claude Haiku 4.5 · API" : "Claude Sonnet 4.6 · API") : "Claude key needed"
            return
        }
        do {
            let all = try await model.availableModels()
            guard let chosen = all.first(where: { $0["name"] as? String == selectedModel }) else { throw JarvisError.message("Local model is not downloaded") }
            try LocalModelPolicy.validate(name: selectedModel, metadata: chosen)
            modelReady = true; modelStatus = selectedModel == "qwen3.5:0.8b" ? "Qwen 0.8B · local" : "Qwen 2B · local"
        } catch { modelReady = false; modelStatus = "Open Ollama / run setup" }
    }

    func setClaps(_ enabled: Bool) {
        clapRearmTask?.cancel()
        if !enabled {
            clapsEnabled = false; clapsArmed = false
            UserDefaults.standard.set(false, forKey: "clapsEnabled")
            pauseMonitoring(); resumeClaps(); return
        }
        Task {
            guard await audio.permission() else { announce("Allow Microphone access for JARVIS in System Settings, then enable the clap trigger."); return }
            clapsEnabled = true; clapsArmed = true
            UserDefaults.standard.set(true, forKey: "clapsEnabled")
            pauseMonitoring()
            resumeClaps()
        }
    }
    private func coolDownClaps() {
        clapsArmed = false
        clapRearmTask?.cancel()
        clapRearmTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self, self.clapsEnabled else { return }
            self.clapsArmed = true
            // A monitor restarted during the cooldown was built without clap detection.
            if self.audio.isMonitoring { self.pauseMonitoring() }
            self.resumeClaps()
        }
    }
    func setHandsFree(_ enabled: Bool) {
        listeningGeneration = UUID()
        if !enabled {
            handsFreeEnabled = false; waitingForCommandUntil = nil
            UserDefaults.standard.set(false, forKey: "handsFreeEnabled")
            pauseMonitoring(); resumeClaps(); return
        }
        Task {
            guard await audio.permission() else { announce("Allow Microphone access for JARVIS in System Settings, then turn on hands-free listening."); return }
            handsFreeEnabled = true
            UserDefaults.standard.set(true, forKey: "handsFreeEnabled")
            pauseMonitoring(); resumeClaps()
        }
    }
    func setListening(_ enabled: Bool) {
        if !enabled { setHandsFree(false); setClaps(false); stop(); return }
        Task {
            guard await audio.permission() else { announce("Allow JARVIS microphone access in System Settings so I can hear you."); return }
            _ = await audio.livePreview.requestPermission()
            handsFreeEnabled = true; clapsEnabled = true; clapsArmed = true
            UserDefaults.standard.set(true, forKey: "handsFreeEnabled")
            UserDefaults.standard.set(true, forKey: "clapsEnabled")
            pauseMonitoring(); resumeClaps()
        }
    }
    private func pauseMonitoring() { audio.stopMonitoring(); listening = false }
    func resumeClaps() {
        guard (clapsEnabled && clapsArmed) || handsFreeEnabled else { return }
        guard !recording, !busy, !voice.isSpeaking, sessionReady else { return }
        do {
            if !audio.isMonitoring { transcript = "" }
            try audio.startMonitoring(claps: clapsEnabled && clapsArmed, handsFree: handsFreeEnabled)
            listening = handsFreeEnabled
            if handsFreeEnabled { status = directListening || waitingForCommandUntil.map { $0 > Date() } == true ? "Listening · speak a command" : "Listening for Jarvis" }
        } catch { listening = false; status = error.localizedDescription }
    }

    private func heardSpeech(_ file: URL, liveText: String? = nil) {
        guard handsFreeEnabled, !busy, !recording, !voice.isSpeaking, sessionReady else {
            // The audio monitor already stopped to deliver this segment; restart it or listening stays dead.
            try? FileManager.default.removeItem(at: file); listening = false; resumeClaps(); return
        }
        let followUp = directListening || (waitingForCommandUntil.map { $0 > Date() } ?? false)
        if let liveText, let words = WakePhrase.command(in: liveText, followUp: followUp),
           !words.isEmpty, CommandParser.parse(words).canUseLiveTranscript {
            try? FileManager.default.removeItem(at: file)
            AudioLog.logger.notice("Hands-free live command accepted after speech pause")
            submit(words, voiceInput: true); return
        }
        liveCommandTask?.cancel()
        pauseMonitoring(); busy = true; status = "Checking speech locally…"
        let generation = listeningGeneration
        operation = Task {
            do {
                let text = try await audio.transcribe(file)
                try Task.checkCancellation()
                guard handsFreeEnabled, generation == listeningGeneration else { busy = false; resumeClaps(); return }
                let followUp = directListening || (waitingForCommandUntil.map { $0 > Date() } ?? false)
                let command = WakePhrase.command(in: text, followUp: followUp)
                busy = false
                guard let command else { status = "Listening for Jarvis"; resumeClaps(); return }
                if command.isEmpty {
                    waitingForCommandUntil = Date().addingTimeInterval(15)
                    status = "Waiting for your command"
                    announce("Yes, boss?")
                    resumeClaps()
                } else {
                    waitingForCommandUntil = nil
                    submit(command, voiceInput: true)
                }
            } catch {
                busy = false
                // Normal background sounds can yield no transcript; do not answer them.
                if !Task.isCancelled, !error.localizedDescription.contains("didn’t catch any speech") {
                    setHandsFree(false)
                    announce("Hands-free listening paused. " + friendly(error))
                }
                status = "Ready when you are"; resumeClaps()
            }
        }
    }

    func toggleRecording() {
        actions.rememberFrontmost()
        if recording {
            recording = false; recordTimer?.cancel()
            guard let file = audio.stopRecording() else { status = "Recording was too short"; resumeClaps(); return }
            busy = true; status = "Transcribing on this Mac…"
            operation = Task {
                do {
                    let text = try await audio.transcribe(file)
                    try Task.checkCancellation()
                    busy = false
                    submit(text, voiceInput: true)
                } catch { busy = false; if !Task.isCancelled { announce(error.localizedDescription) }; status = "Ready when you are"; resumeClaps() }
            }
            return
        }
        guard !busy else { return }
        Task {
            guard await audio.permission() else { announce("Allow Microphone access for JARVIS in System Settings to use local voice input."); return }
            guard !busy, !recording else { return }
            voice.stop()
            do {
                pauseMonitoring()
                try audio.startRecording(); recording = true; status = "Listening · press ⌥ Space to finish"
                recordTimer = Task {
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    if !Task.isCancelled, recording { toggleRecording() }
                }
            } catch { announce(error.localizedDescription); resumeClaps() }
        }
    }

    func prepareTypedCommand() {
        liveCommandTask?.cancel()
        earlyOpenTask?.cancel(); earlyOpenCandidate = nil
        pauseMonitoring()
    }

    func submit(_ text: String, voiceInput: Bool = false) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let command = instagram.followUp(text).map(Command.instagram) ?? CommandParser.parse(text)
        if command == .stop { stop(); return }
        guard !busy, !recording else { return }
        currentInputIsVoice = voiceInput
        liveCommandTask?.cancel()
        earlyOpenTask?.cancel(); earlyOpenCandidate = nil
        if !voiceInput { earlyOpenedApp = nil }
        transcript = text
        recipients = []; pendingMessage = ""
        entries.append(ConversationEntry(user: true, text: text))
        trimEntries()
        waitingForCommandUntil = nil
        busy = true; status = "On it…"; pauseMonitoring(); voice.stop()
        // Dispatch the prepared local greeting before scheduling any app/network/model work.
        if command == .briefing { welcome() }
        operation = Task {
            defer { busy = false; earlyOpenedApp = nil; status = "Ready when you are"; resumeClaps() }
            do {
                try await execute(command)
            } catch {
                if !Task.isCancelled { announce(friendly(error)) }
            }
        }
    }

    private func execute(_ command: Command) async throws {
        switch command {
        case .stop: stop()
        case .help: announce("Turn on JARVIS listening in the menu bar. Say Jarvis, followed by your command, then pause. Try: can you open the Notes app; give me Indian market news; Bitcoin price; or brief me. Option Escape stops work.")
        case .greet: welcome()
        case .hearingCheck:
            announce(currentInputIsVoice ? "Yes, boss. Your voice is coming through." : "I can read your message. Turn on JARVIS listening, then say Jarvis, can you hear me.")
        case .open(let name):
            if earlyOpenedApp == name.lowercased(), Date().timeIntervalSince(earlyOpenedAt) < 15 { announce("\(name.capitalized) is open.") }
            else { try respond(await actions.open(name)) }
        case .search(let query): try respond(await actions.search(query))
        case .instagram(let command):
            status = "Instagram…"
            try respond(await instagram.run(command))
        case .sequence(let commands):
            for command in commands.prefix(4) { try Task.checkCancellation(); try await execute(command) }
        case .switchTab(let query): try respond(await actions.switchTab(query))
        case .note(let title, let body): try respond(await actions.note(title: title, body: body))
        case .type(let text): try respond(await actions.type(text))
        case .message(let name, let body):
            let matches = try await actions.recipients(name)
            try Task.checkCancellation()
            if let recipient = MessageRecipient.automaticRecipient(in: matches) {
                do { try respond(await actions.send(to: recipient, text: body)) }
                catch { throw JarvisError.message("Send result could not be verified. Check Messages before retrying.\n" + error.localizedDescription) }
            }
            else {
                recipients = matches; pendingMessage = body
                let reason = matches.count == 1
                    ? "I found \(matches[0].name), but the name did not match exactly."
                    : "More than one contact address matches."
                announce(reason + " Repeat the command with the full phone number or email, or choose the address from JARVIS’s menu bar. The message has not been sent.")
            }
        case .summarizeSelection: try await summarize(actions.selectedText(), source: "Selected text")
        case .summarize(let text): try await summarize(text, source: "Provided text")
        case .summarizePage:
            let page = try await actions.currentPage()
            try await summarize(page.text, source: "\(page.title)\n\(page.url)")
        case .chat(let text):
            if jevEnabled, let routed = try? await jev.route(text) {
                try Task.checkCancellation(); try await execute(routed)
            } else { try await generate(String(text.prefix(6000)), summary: false) }
        case .markets(let scope): try await marketBriefing(scope)
        case .browse(let task):
            guard !criticalMemory || usesClaude else { throw JarvisError.message("Local browser reasoning is paused while memory pressure is critical.") }
            append("Browser mode reads the current Chrome tab and can follow up to three links on the same site. It does not submit forms.")
            var page = try await actions.browserSnapshot()
            var visited: Set<String> = [page.url]
            for step in 1...3 {
                try Task.checkCancellation()
                status = "Browser · choosing step \(step) of 3…"
                let index: Int
                if jevEnabled { index = try await jev.chooseBrowserLink(task: task, snapshot: page) }
                else if usesClaude { index = try await claude.chooseBrowserLink(task: task, snapshot: page, model: selectedModel) }
                else { index = try await model.chooseBrowserLink(task: task, snapshot: page, model: selectedModel) }
                if index == -1 { break }
                guard let link = page.links.first(where: { $0.index == index }), !visited.contains(link.url) else { break }
                append("Opening: \(link.label)\n\(link.url)")
                try await actions.follow(link, in: page)
                visited.insert(link.url)
                let next = try await actions.browserSnapshot(windowID: page.windowID, tabID: page.tabID)
                guard URL(string: next.url)?.host == URL(string: page.url)?.host else { throw JarvisError.message("The page redirected to another site. The browser task stopped there.") }
                page = next
            }
            try await summarize("Task: \(task)\nSource:\n\(page.text)", source: "Browser result: \(page.title)\n\(page.url)")
        case .briefing: try await briefing()
        }
    }

    func sendSelected(_ recipient: MessageRecipient) {
        guard !busy, !pendingMessage.isEmpty else { return }
        let text = pendingMessage
        recipients = []; pendingMessage = ""; busy = true; status = "Submitting iMessage…"
        operation = Task {
            defer { busy = false; status = "Ready when you are"; resumeClaps() }
            do { try respond(await actions.send(to: recipient, text: text)) }
            catch { announce("Send result could not be verified. Check Messages before retrying.\n" + friendly(error)) }
        }
    }

    private func briefing() async throws {
        // Start public-data requests before app launching; the welcome is already playing.
        async let marketReport = markets.report(.all, overnight: true)
        announce(OfficeGreeting.text())
        do { _ = try await actions.open("outlook") }
        catch { append("Outlook could not open: " + friendly(error)) }
        let report = try await marketReport
        append(report.spoken + "\n\n" + report.details); speak(report.spoken)
        try Task.checkCancellation()
        if mail.connected {
            do {
                status = "Reading recent unread inbox previews…"
                let messages = try await mail.unread()
                if messages.isEmpty { announce("No unread inbox messages from the past seven days.") }
                else {
                    let source = messages.enumerated().map { index, mail in "\(index + 1). \(mail.subject)\nFrom: \(mail.sender)\nReceived: \(mail.received)\nPreview: \(mail.body)" }.joined(separator: "\n\n")
                    try await summarize(source, source: "Up to five unread inbox previews from the past seven days. These are previews, not full messages.")
                    append(messages.map { "\($0.subject)\n\($0.link)" }.joined(separator: "\n\n"))
                }
            } catch { if Task.isCancelled { throw CancellationError() }; announce(friendly(error)) }
        } else { append("Connect Microsoft 365 in JARVIS settings to include unread email previews, or select an email and say summarize this email.") }
        try Task.checkCancellation()
        do { _ = try await actions.open("wsj") }
        catch { append("WSJ could not open: " + friendly(error)) }
    }

    private func marketBriefing(_ scope: MarketScope) async throws {
        status = "Fetching current market sources…"
        let report = try await markets.report(scope)
        try Task.checkCancellation()
        append(report.spoken + "\n\n" + report.details)
        speak(report.spoken)
    }

    private func summarize(_ text: String, source: String) async throws {
        let excerpt = ContentBudget.excerpt(text)
        guard !excerpt.text.isEmpty else { throw JarvisError.message("There is no readable text to summarize.") }
        append(source + (excerpt.truncated ? "\nOnly the first 6,000 characters will be summarized." : ""))
        try await generate(excerpt.text, summary: true)
    }

    private func generate(_ text: String, summary: Bool) async throws {
        guard !criticalMemory || usesClaude else { throw JarvisError.message("The local model is paused because this Mac is under critical memory pressure. Basic app commands still work.") }
        status = usesClaude ? "Asking Claude…" : "Thinking locally…"
        speechChunks = SpeechChunks()
        let entry = ConversationEntry(user: false, text: "")
        entries.append(entry)
        do {
            let tokenHandler: @Sendable (String) async -> Void = { [weak self] partial in
                await self?.updatePartial(partial, id: entry.id)
            }
            let output = usesClaude
                ? try await claude.reply(to: text, model: selectedModel, summary: summary, voiceInput: currentInputIsVoice, onToken: tokenHandler)
                : try await model.reply(to: text, model: selectedModel, summary: summary, voiceInput: currentInputIsVoice, onToken: tokenHandler)
            try Task.checkCancellation()
            if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index].text = output }
            for chunk in speechChunks.consume(output, final: true) { speak(chunk) }
        } catch {
            if let index = entries.firstIndex(where: { $0.id == entry.id }), entries[index].text.isEmpty { entries.remove(at: index) }
            await model.unload(selectedModel)
            throw error
        }
    }

    func stop() {
        instagram.cancel()
        liveCommandTask?.cancel()
        earlyOpenTask?.cancel(); earlyOpenCandidate = nil; earlyOpenedApp = nil
        operation?.cancel(); recordTimer?.cancel(); voice.stop(); audio.cancel(); recording = false; listening = false
        waitingForCommandUntil = nil
        transcript = ""
        recipients = []; pendingMessage = ""; status = busy ? "Stopping…" : "Stopped"
        Task { await model.unload(selectedModel) }
        // Stopping playback does not invoke AVAudioPlayer's finish callback. Restore an
        // opted-in listener explicitly; sleep/lock/disabled-listening guards still apply.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            self?.resumeClaps()
        }
    }
    private func updatePartial(_ text: String, id: UUID) {
        guard !Task.isCancelled, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].text = text
        for chunk in speechChunks.consume(text) { speak(chunk) }
    }
    private func respond(_ text: String) throws { try Task.checkCancellation(); append(text); speak(text) }
    private func speak(_ text: String) { if speakReplies { pauseMonitoring(); voice.say(text) } }
    private func welcome() {
        append("Welcome to the office, boss.")
        if speakReplies { pauseMonitoring(); voice.welcome() }
    }
    private func announce(_ text: String) { append(text); speak(text) }
    var lastResponse: String { entries.last(where: { !$0.user && !$0.text.isEmpty })?.text ?? "No response yet." }
    func readLastResponse() { pauseMonitoring(); voice.stop(); voice.say(lastResponse) }
    func append(_ text: String) { entries.append(ConversationEntry(user: false, text: text)); trimEntries() }
    private func trimEntries() { if entries.count > 30 { entries.removeFirst(entries.count - 30) } }
    private func friendly(_ error: Error) -> String {
        let message = error.localizedDescription
        if message.contains("-1743") { return "Allow JARVIS to control this app in System Settings → Privacy & Security → Automation, then retry." }
        if message.contains("JavaScript") { return "To read Chrome pages, enable View → Developer → Allow JavaScript from Apple Events in Chrome. Or select text and use ‘summarize this’." }
        return message
    }
}
