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

            Divider()

            Button {
                openWindow(id: "murmel-main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Verlauf & Wörterbuch", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            footer
        }
        .padding(14)
        .frame(width: 300)
        .onChange(of: settings.hotkeyTrigger) { _, newValue in
            coordinator.updateTrigger(newValue)
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Murmel").font(.headline)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
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
