import AppKit
import SwiftUI
import Combine

private final class CommandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CommandHUD {
    private let panel: NSPanel
    private var observation: AnyCancellable?
    private var dismiss: Task<Void, Never>?
    private weak var model: AppModel?
    init(model: AppModel) {
        self.model = model
        panel = CommandPanel(contentRect: NSRect(x: 0, y: 0, width: 190, height: 34), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: CommandHUDView(model: model))
        observation = Publishers.CombineLatest4(model.$transcript, model.$busy, model.$recording, model.$handsFreeEnabled)
            .sink { [weak self] transcript, busy, recording, enabled in
                Task { @MainActor in self?.update(text: transcript, busy: busy, recording: recording, enabled: enabled) }
            }
    }
    private func update(text: String, busy: Bool, recording: Bool, enabled: Bool) {
        dismiss?.cancel()
        guard enabled || busy || recording || !text.isEmpty else { panel.orderOut(nil); return }
        let expanded = busy || recording || !text.isEmpty
        let width: CGFloat = expanded ? 374 : 190, height: CGFloat = expanded ? 48 : 34
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.maxY - height - 6, width: width, height: height), display: true, animate: panel.isVisible)
        }
        panel.orderFrontRegardless()
        if !busy && !recording && !text.isEmpty {
            dismiss = Task { [weak self] in
                let preview = ProcessInfo.processInfo.arguments.contains("--preview-command-bar")
                try? await Task.sleep(nanoseconds: preview ? 30_000_000_000 : 3_500_000_000)
                guard !Task.isCancelled else { return }; self?.model?.transcript = ""
            }
        }
    }
}

private struct CommandHUDView: View {
    @ObservedObject var model: AppModel
    private var expanded: Bool { model.busy || model.recording || !model.transcript.isEmpty }
    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(model.listening ? Color.white.opacity(0.9) : Color.white.opacity(0.35)).frame(width: 5, height: 5)
                .accessibilityLabel(model.listening ? "Listening" : "Listening paused")
            VStack(alignment: .leading, spacing: 2) {
                Text(expanded ? (model.transcript.isEmpty ? "JARVIS" : model.transcript) : "JARVIS")
                    .font(.system(size: expanded ? 11.5 : 10.5, weight: .medium)).lineLimit(1).truncationMode(.head)
                if expanded { Text(model.status).font(.system(size: 9)).foregroundStyle(.white.opacity(0.6)).lineLimit(1) }
            }
            if !expanded { Text(model.listening ? "listening" : "paused").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)) }
            Spacer(minLength: 0)
            if expanded {
                Button(action: model.stop) { Image(systemName: "stop.fill").font(.system(size: 7)).padding(5) }
                    .buttonStyle(.plain).help("Stop JARVIS").accessibilityLabel("Stop JARVIS")
            }
            Menu {
                Toggle("Listening", isOn: Binding(get: { model.handsFreeEnabled }, set: { model.setListening($0) }))
                Button("Type a command…") { model.onTypeRequested?() }.disabled(model.busy || model.recording)
                Button("Copy last response") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.lastResponse, forType: .string)
                }
                Text(model.clapStatus)
                Divider()
                Text(String(model.lastResponse.prefix(220))).disabled(true)
            } label: { Image(systemName: "ellipsis").font(.system(size: 10)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("JARVIS controls")
        }
        .padding(.horizontal, 13).frame(width: expanded ? 370 : 186, height: expanded ? 44 : 30)
        .foregroundStyle(.white)
        .modifier(BlackGlass())
        .preferredColorScheme(.dark)
        .padding(2)
    }
}

private struct BlackGlass: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.background(.black.opacity(0.8), in: Capsule())
                .glassEffect(.regular.tint(.black), in: Capsule())
                .environment(\.colorScheme, .dark)
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
                .background(.black.opacity(0.78), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
        }
    }
}
