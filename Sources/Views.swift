import SwiftUI
import AppKit
import ServiceManagement

// Created only when Settings is explicitly selected from the native menu bar.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var mail: MicrosoftMail
    let close: () -> Void
    @AppStorage("microsoftClientID") private var clientID = ""
    @State private var signInTask: Task<Void, Never>?
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError = ""
    @State private var typeSafeKey = ""
    @State private var keyStatus = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Voice & activation") {
                    LabeledContent("Voice", value: "Robotic female")
                    Text(model.directListening ? "While listening is on, speak commands directly. The small bar shows your words. Opening and search commands use live recognition; messages and notes wait for the completed recording." : "Say Jarvis followed by your command. The small bar shows your words using on-device speech recognition.").font(.callout).foregroundStyle(.secondary)
                    Toggle("JARVIS listening · voice and claps", isOn: Binding(get: { model.handsFreeEnabled || model.clapsEnabled }, set: { model.setListening($0) }))
                    Toggle("Accept commands without saying Jarvis", isOn: $model.directListening)
                    Toggle("Speak replies", isOn: $model.speakReplies).onChange(of: model.speakReplies) { _, enabled in if !enabled { model.voice.stop() } }
                    if model.clapsEnabled {
                        LabeledContent("Claps", value: model.clapStatus)
                        if !model.clapsArmed { Button("Rearm claps") { model.setClaps(true) } }
                    }
                    Text("Say “Hey Jarvis, Aryan here to start working” for the welcome and overnight briefing. Two claps also start Office mode. Listening pauses during replies. ⌥ Esc stops work.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Start at login", isOn: $loginEnabled).onChange(of: loginEnabled) { _, enabled in
                        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginError = "" }
                        catch { loginError = error.localizedDescription }
                    }
                    if !loginError.isEmpty { Text(loginError).font(.caption).foregroundStyle(.orange) }
                }
                Section("Assistant model") {
                    Picker("Model", selection: $model.selectedModel) {
                        Text("Claude Sonnet 4.6 · API").tag("claude-sonnet-4-6")
                        Text("Claude Haiku 4.5 · faster API option").tag("claude-haiku-4-5-20251001")
                        Text("Qwen 0.8B · lightest").tag("qwen3.5:0.8b")
                        Text("Qwen 2B · requires download").tag("qwen3.5:2b")
                    }.disabled(model.busy)
                    HStack { Text(model.modelStatus).font(.caption); Spacer(); Button("Check") { Task { await model.refreshModel() } } }
                    Text(model.usesClaude ? "Claude uses paid Anthropic credits. Commands, conversation and requested summaries go to Anthropic; microphone audio stays on this Mac. Keys are kept in Keychain." : "Local models unload after each response. \(model.memoryStatus).").font(.caption).foregroundStyle(.secondary)
                }
                Section("Microsoft 365 · work or school") {
                    Text(mail.status).font(.callout)
                    if !mail.connected {
                        TextField("Entra application ID", text: $clientID)
                        Text("Use an organization-approved public-client app with Mail.Read and device-code sign-in. No client secret is needed.").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(mail.signingIn ? "Waiting for sign-in…" : "Connect mailbox") { signInTask = Task { await mail.signIn(clientID: clientID) } }.disabled(mail.signingIn)
                            if mail.signingIn { Button("Cancel") { signInTask?.cancel() } }
                        }
                    } else { Button("Disconnect") { mail.disconnect() } }
                    if !mail.deviceCode.isEmpty, let url = mail.verificationURL {
                        Text(mail.deviceCode).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                        Link("Open Microsoft sign-in", destination: url)
                    }
                }
                Section("Jev · TypeSafe") {
                    Text(model.jevStatus).font(.caption)
                    Toggle("Use Jev for intent and browser link decisions", isOn: $model.jevEnabled).disabled(model.busy)
                    SecureField("TypeSafe API key", text: $typeSafeKey)
                    HStack {
                        Button("Save key to Keychain") {
                            do { try JevCredentials.save(typeSafeKey); typeSafeKey = ""; model.jevEnabled = true; keyStatus = "Key saved"; Task { await model.refreshModel() } }
                            catch { keyStatus = error.localizedDescription }
                        }.disabled(typeSafeKey.isEmpty)
                        Link("Get API key", destination: URL(string: "https://console.typesafe.ai/")!)
                    }
                    if !keyStatus.isEmpty { Text(keyStatus).font(.caption) }
                    Text("Paid TypeSafe API. Jev chooses app intents, reading links and compatible Instagram controls. Instagram supports profile search, voice disambiguation, literal drafts and explicit sends. Booking and checkout are not connected.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Chrome & Mac access") {
                    Text("For page summaries, enable Chrome → View → Developer → Allow JavaScript from Apple Events. Use your signed-in WSJ tabs.").font(.caption).foregroundStyle(.secondary)
                    Text("Microphone access is requested when you record or enable claps. Typing and reading selected text require Accessibility access.").font(.caption).foregroundStyle(.secondary)
                    Button("Open Accessibility settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
                }
            }.formStyle(.grouped)
            Divider()
            HStack { Spacer(); Button("Done", action: close).keyboardShortcut(.defaultAction) }.padding(14)
        }.frame(width: 520, height: 690)
            .onChange(of: model.selectedModel) { _, _ in Task { await model.refreshModel() } }
            .onDisappear { signInTask?.cancel() }
            .onExitCommand(perform: close)
    }
}
