import SwiftUI
import AppKit

/// Ersteinrichtungs-Fenster: prüft die Infrastruktur und installiert Fehlendes mit
/// einem Klick (mit Zwischenfrage vor den großen Downloads). Erscheint automatisch
/// beim ersten Start, wenn etwas fehlt — und ist über das Menü erneut aufrufbar.
struct SetupView: View {
    @ObservedObject var manager: SetupManager
    @State private var didCheck = false
    @State private var confirmDownloads = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            VStack(spacing: 8) {
                ForEach(SetupManager.Step.allCases) { step in
                    row(step)
                }
            }

            if needsHomebrew {
                homebrewHint
            }

            if !manager.logLines.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(manager.logLines.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.system(size: 11, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                    }
                    .frame(height: 110)
                    .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .onChange(of: manager.logLines.count) { _, _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }

            footer
        }
        .padding(22)
        .frame(width: 520)
        .task {
            if !didCheck { didCheck = true; await manager.checkAll() }
        }
    }

    // MARK: - Teile

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(manager.isComplete ? "Murmel ist startklar 🎉" : "Murmel einrichten")
                .font(.title2.weight(.semibold))
            Text(manager.isComplete
                 ? "Alles vorhanden — du kannst loslegen: fn halten und sprechen."
                 : "Murmel läuft 100 % lokal. Einmal einrichten, dann nie wieder. Kein Abo, keine Cloud.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func row(_ step: SetupManager.Step) -> some View {
        let st = manager.status[step] ?? .unknown
        return HStack(alignment: .top, spacing: 11) {
            icon(for: st).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.title).font(.system(size: 13, weight: .medium))
                Text(statusText(st, step)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func icon(for st: SetupManager.Status) -> some View {
        switch st {
        case .present, .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .installing, .checking:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        default:
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }

    private func statusText(_ st: SetupManager.Status, _ step: SetupManager.Step) -> String {
        switch st {
        case .present:        return "vorhanden"
        case .done:           return "installiert"
        case .checking:       return "prüfe …"
        case .installing:     return "wird eingerichtet …"
        case .missing:        return step.detail
        case .failed(let m):  return m
        case .unknown:        return step.detail
        }
    }

    private var needsHomebrew: Bool {
        if case .present = manager.status[.homebrew] { return false }
        if case .done = manager.status[.homebrew] { return false }
        if manager.status[.homebrew] == nil || manager.status[.homebrew] == .checking { return false }
        return true
    }

    private var homebrewHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Homebrew fehlt — bitte einmal manuell installieren:")
                .font(.caption.weight(.medium))
            HStack {
                Text("Befehl in Terminal").font(.caption)
                Spacer()
                Button("Befehl kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(SetupManager.homebrewInstallCommand, forType: .string)
                }
                Button("brew.sh öffnen") {
                    if let u = URL(string: "https://brew.sh") { NSWorkspace.shared.open(u) }
                }
            }
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack {
            Button("Erneut prüfen") {
                Task { await manager.checkAll() }
            }
            .disabled(manager.isBusy)

            Spacer()

            if manager.isComplete {
                Button("Fertig") { closeWindow() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button {
                    confirmDownloads = true
                } label: {
                    Text(manager.isBusy ? "Richte ein …" : "Jetzt einrichten")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(manager.isBusy)
            }
        }
        .confirmationDialog(
            "Murmel lädt jetzt die lokalen Modelle (~4 GB) und richtet alles ein. Das kann je nach Verbindung einige Minuten dauern. Fortfahren?",
            isPresented: $confirmDownloads, titleVisibility: .visible
        ) {
            Button("Einrichten") { Task { await manager.installMissing() } }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    private func closeWindow() {
        NSApp.keyWindow?.close()
    }
}

/// Verwaltet das Ersteinrichtungs-Fenster als echtes NSWindow — zuverlässig aus jedem
/// Kontext (App-Start ODER Menü) aufrufbar, anders als SwiftUI-`Window`-Szenen, die in
/// einer Accessory-App schwer aus dem AppDelegate heraus zu öffnen sind.
@MainActor
final class SetupWindow: NSObject, NSWindowDelegate {
    static let shared = SetupWindow()
    private var window: NSWindow?

    func show(_ manager: SetupManager) {
        if window == nil {
            let host = NSHostingController(rootView: SetupView(manager: manager))
            let w = NSWindow(contentViewController: host)
            w.title = "Murmel — Einrichtung"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        // Während der Einrichtung kurz zur normalen App werden (Dock-Icon + sicherer Fokus),
        // danach (Fenster zu) wieder reine Menüleisten-App.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
