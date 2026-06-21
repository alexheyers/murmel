import SwiftUI

/// Das Panel, das beim Klick auf das Menubar-Icon erscheint.
struct MenuBarView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var settings = Settings.shared

    @State private var historyQuery = ""
    @State private var history: [HistoryEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            stylePicker

            triggerPicker

            Toggle("Bei Anmeldung starten", isOn: $settings.launchAtLogin)
                .toggleStyle(.checkbox)

            Divider()

            historySection

            Divider()

            footer
        }
        .padding(14)
        .frame(width: 320)
        .onAppear(perform: refreshHistory)
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

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Verlauf").font(.subheadline).bold()
            TextField("Suchen…", text: $historyQuery)
                .textFieldStyle(.roundedBorder)
                .onChange(of: historyQuery) { _, _ in refreshHistory() }

            if history.isEmpty {
                Text("Noch keine Diktate.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(history) { entry in
                            Button {
                                coordinator.reinsert(entry)
                            } label: {
                                Text(entry.final)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .help("Erneut einfügen")
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
        }
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

    private func refreshHistory() {
        if historyQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            history = coordinator.recentHistory(limit: 10)
        } else {
            history = coordinator.searchHistory(historyQuery)
        }
    }

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
