import SwiftUI

/// Verwaltungsfenster mit vier Tabs: Verlauf, Modi, Wörterbuch, Analyse.
struct ManagementView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        TabView {
            HistoryTab(coordinator: coordinator)
                .tabItem { Label("Verlauf", systemImage: "clock") }

            ModiTab(settings: coordinator.settings)
                .tabItem { Label("Modi", systemImage: "slider.horizontal.3") }

            VocabularyTab(store: coordinator.vocabulary)
                .tabItem { Label("Wörterbuch", systemImage: "character.book.closed") }

            AnalyseTab(coordinator: coordinator)
                .tabItem { Label("Analyse", systemImage: "waveform.and.magnifyingglass") }
        }
        .frame(width: 600, height: 540)
        .background(.regularMaterial)
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
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Verlauf durchsuchen…", text: $query)
                    .textFieldStyle(.plain)
                    .onChange(of: query) { _, _ in refresh() }
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Aktualisieren")
            }
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))

            if items.isEmpty {
                emptyState("Noch keine Diktate.", "clock")
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(items) { entry in
                            VStack(alignment: .leading, spacing: 6) {
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
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 11))
                        }
                    }
                }
            }
        }
        .padding(16)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        items = query.trimmingCharacters(in: .whitespaces).isEmpty
            ? coordinator.recentHistory(limit: 50)
            : coordinator.searchHistory(query)
    }
}

// MARK: - Modi

private struct ModiTab: View {
    @ObservedObject var settings: Settings
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Stil-Modus — bestimmt, wie Murmel dein Diktat formuliert.")
                .font(.callout).foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(DictationStyle.allCases) { style in
                    Button {
                        settings.currentStyle = style
                        draft = settings.instruction(for: style)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: settings.currentStyle == style ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(settings.currentStyle == style ? Color.accentColor : .secondary)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(style.displayName).fontWeight(.semibold)
                                    if settings.hasCustomInstruction(for: style) {
                                        Text("angepasst").font(.caption2)
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                                    }
                                }
                                Text(style.summary).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(settings.currentStyle == style ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                                    in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            if settings.currentStyle.usesPolish {
                Text("Formulierung für \(settings.currentStyle.displayName)")
                    .font(.subheadline).bold()
                Text("Diese Anweisung bekommt das lokale Modell. Pass sie an, wie der Text klingen soll.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft)
                    .font(.callout).frame(height: 84)
                    .padding(6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .scrollContentBackground(.hidden)
                HStack {
                    Button("Speichern") { settings.setInstruction(draft, for: settings.currentStyle) }
                        .buttonStyle(.borderedProminent)
                    Button("Auf Standard zurücksetzen") {
                        settings.resetInstruction(for: settings.currentStyle)
                        draft = settings.currentStyle.polishInstruction
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
            } else {
                Label("Roh fügt genau das gesprochene Wort ein — keine Politur, kein Modell.",
                      systemImage: "checkmark.seal")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .onAppear { draft = settings.instruction(for: settings.currentStyle) }
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
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("gesprochen / falsch", text: $newWrong).textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("korrekt", text: $newRight).textFieldStyle(.roundedBorder)
                Button("Hinzufügen") { add() }.disabled(!canAdd).buttonStyle(.borderedProminent)
            }

            if store.entries.isEmpty {
                emptyState("Noch keine Einträge.", "character.book.closed")
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(store.entries) { entry in
                            HStack(spacing: 8) {
                                Text(entry.wrong).foregroundStyle(.secondary)
                                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                                Text(entry.right).bold()
                                Spacer()
                                Button(role: .destructive) { store.removeEntry(entry) } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless).help("Löschen")
                            }
                            .padding(10)
                            .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                        }
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
        newWrong = ""; newRight = ""
    }
}

// MARK: - Analyse

private struct AnalyseTab: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var a = SpeechAnalysis()

    private let chipCols = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    statCard("\(a.dictations)", "Diktate")
                    statCard("\(a.totalWords)", "Wörter")
                    statCard(String(format: "%.0f", a.avgWords), "Ø / Diktat")
                    statCard(String(format: "%.0f", a.avgSentenceLength), "Ø / Satz")
                }

                if !a.fillers.isEmpty {
                    sectionTitle("Füllwörter", "die du oft sagst")
                    LazyVGrid(columns: chipCols, alignment: .leading, spacing: 8) {
                        ForEach(a.fillers, id: \.word) { f in
                            chip(f.word, "\(f.count)×", tint: .orange)
                        }
                    }
                }

                if !a.topWords.isEmpty {
                    sectionTitle("Häufige Begriffe", "dein Vokabular")
                    LazyVGrid(columns: chipCols, alignment: .leading, spacing: 8) {
                        ForEach(a.topWords, id: \.word) { w in
                            chip(w.word, "\(w.count)×", tint: .accentColor)
                        }
                    }
                }

                sectionTitle("Lern-Tipps", "wie du noch klarer sprichst")
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(a.tips.enumerated()), id: \.offset) { _, tip in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "lightbulb").foregroundStyle(.yellow)
                            Text(tip).font(.callout)
                        }
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 11))
                    }
                }
            }
            .padding(16)
        }
        .onAppear { a = SpeechAnalyzer.analyze(coordinator.recentHistory(limit: 1000)) }
    }

    private func statCard(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func sectionTitle(_ t: String, _ sub: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(t).font(.subheadline).bold()
            Text(sub).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func chip(_ a: String, _ b: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(a).font(.callout)
            Text(b).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

// MARK: - Shared

private func emptyState(_ text: String, _ symbol: String) -> some View {
    VStack(spacing: 10) {
        Spacer()
        Image(systemName: symbol).font(.largeTitle).foregroundStyle(.tertiary)
        Text(text).foregroundStyle(.secondary)
        Spacer()
    }
    .frame(maxWidth: .infinity)
}
