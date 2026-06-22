import SwiftUI

/// Das Panel, das beim Klick auf das Menubar-Icon erscheint.
struct MenuBarView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var settings = Settings.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            stylePicker

            triggerPicker

            Toggle("Bei Anmeldung starten", isOn: $settings.launchAtLogin)
                .toggleStyle(.checkbox)

            Toggle("Live-Vorschau beim Sprechen", isOn: $settings.streamingEnabled)
                .toggleStyle(.checkbox)
                .help("Zeigt während des Sprechens fortlaufend Text in einem Overlay (lokales base-Modell).")

            Toggle("Modus automatisch je App", isOn: $settings.autoStyleByApp)
                .toggleStyle(.checkbox)
                .help("Nur im Roh-Modus: wählt den Stil nach aktiver App (Terminal→Roh, Mail→E-Mail, Notion→Brainstorming).")

            Toggle("Antworten vorlesen", isOn: $settings.speakAnswers)
                .toggleStyle(.checkbox)
                .help("Liest Assistent-/Zusammenfassen-Antworten nach dem Einfügen laut vor (lokale Stimme).")

            Divider()

            Button {
                openWindow(id: "murmel-main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Verlauf · Modi · Wörterbuch · Analyse", systemImage: "square.grid.2x2")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.large)

            HStack {
                Button("Zwischenablage vorlesen") { coordinator.speakClipboard() }
                Button("Vorlesen stoppen") { coordinator.stopSpeaking() }
            }

            Divider()

            footer
        }
        .padding(16)
        .frame(width: 312)
        .background(.ultraThinMaterial)
        .onChange(of: settings.hotkeyTrigger) { _, newValue in
            coordinator.updateTrigger(newValue)
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(statusColor.opacity(0.16))
                    .frame(width: 36, height: 36)
                Image(systemName: statusSymbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(statusColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Murmel").font(.headline)
                Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
        }
    }

    private var stylePicker: some View {
        Picker("Stil", selection: $settings.currentStyle) {
            ForEach(DictationStyle.allCases) { style in
                Text(style.displayName).tag(style)
            }
        }
        .pickerStyle(.menu)
    }

    private var triggerPicker: some View {
        Picker("Taste", selection: $settings.hotkeyTrigger) {
            ForEach(HotkeyTrigger.allCases) { t in
                Text(t.displayName).tag(t)
            }
        }
        .pickerStyle(.menu)
    }

    private var footer: some View {
        HStack {
            if !Permissions.hasAccessibility {
                Button("Rechte erteilen") {
                    Permissions.openAccessibilitySettings()
                }
            }
            Spacer()
            Button("Beenden") { NSApplication.shared.terminate(nil) }
        }
    }

    // MARK: Helpers

    private var statusText: String {
        switch coordinator.phase {
        case .idle:          return "Bereit — \(settings.hotkeyTrigger.displayName) halten"
        case .recording:     return "Aufnahme…"
        case .transcribing:  return "Transkribiere…"
        case .polishing:     return "Poliere…"
        case .inserting:     return "Füge ein…"
        case .error(let m):  return m
        }
    }

    private var statusSymbol: String {
        switch coordinator.phase {
        case .idle:         return "mic"
        case .recording:    return "mic.fill"
        case .transcribing, .polishing, .inserting: return "waveform"
        case .error:        return "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch coordinator.phase {
        case .recording: return .red
        case .error:     return .orange
        default:         return .primary
        }
    }
}
