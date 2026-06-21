import SwiftUI

/// Das Verwaltungsfenster mit zwei Tabs: Verlauf und Wörterbuch.
/// Wird aus dem Menubar-Panel geöffnet.
struct ManagementView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        TabView {
            HistoryTab(coordinator: coordinator)
                .tabItem { Label("Verlauf", systemImage: "clock") }

            VocabularyTab(store: coordinator.vocabulary)
                .tabItem { Label("Wörterbuch", systemImage: "character.book.closed") }
        }
        .frame(width: 540, height: 480)
    }
}

// MARK: - Verlauf

private struct HistoryTab: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var query = ""
    @State private var items: [HistoryEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Verlauf durchsuchen…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: query) { _, _ in refresh() }
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Aktualisieren")
            }

            if items.isEmpty {
                Spacer()
                Text("Noch keine Diktate.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                List(items) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.final).lineLimit(4)
                        HStack(spacing: 8) {
                            Text(entry.timestamp, style: .date)
                            Text(entry.timestamp, style: .time)
                            Text(entry.style.displayName)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                            Spacer()
                            Button("Einfügen") { coordinator.reinsert(entry) }
                                .buttonStyle(.borderless)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .padding(16)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            items = coordinator.recentHistory(limit: 50)
        } else {
            items = coordinator.searchHistory(query)
        }
    }
}

// MARK: - Wörterbuch

private struct VocabularyTab: View {
    @ObservedObject var store: VocabularyStore
    @State private var newWrong = ""
    @State private var newRight = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Eigene Begriffe: links, wie Whisper es (falsch) hört — rechts, wie es korrekt geschrieben wird.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("gesprochen / falsch", text: $newWrong)
                    .textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("korrekt", text: $newRight)
                    .textFieldStyle(.roundedBorder)
                Button("Hinzufügen") { add() }
                    .disabled(!canAdd)
            }

            if store.entries.isEmpty {
                Spacer()
                Text("Noch keine Einträge.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                List {
                    ForEach(store.entries) { entry in
                        HStack(spacing: 8) {
                            Text(entry.wrong).foregroundStyle(.secondary)
                            Image(systemName: "arrow.right")
                                .font(.caption2).foregroundStyle(.tertiary)
                            Text(entry.right).bold()
                            Spacer()
                            Button(role: .destructive) {
                                store.removeEntry(entry)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Löschen")
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding(16)
    }

    private var canAdd: Bool {
        !newWrong.trimmingCharacters(in: .whitespaces).isEmpty &&
        !newRight.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func add() {
        store.addEntry(wrong: newWrong, right: newRight)
        newWrong = ""
        newRight = ""
    }
}
