import Foundation
import ServiceManagement

/// Zentrale Konfiguration. UserDefaults-gestützt, beobachtbar von der UI.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    // MARK: Persistierte Einstellungen

    @Published var currentStyle: DictationStyle {
        didSet { defaults.set(currentStyle.rawValue, forKey: Keys.style) }
    }

    @Published var hotkeyTrigger: HotkeyTrigger {
        didSet { defaults.set(hotkeyTrigger.rawValue, forKey: Keys.trigger) }
    }

    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin(launchAtLogin) }
    }

    /// Live-Vorschau (Streaming): zeigt während des Sprechens fortlaufend Text in einem Overlay.
    @Published var streamingEnabled: Bool {
        didSet { defaults.set(streamingEnabled, forKey: Keys.streaming) }
    }

    /// Auto-Modus: wählt den Diktat-Stil automatisch nach der aktiven App — aber nur,
    /// solange der Nutzer auf dem Standard-Stil `.raw` steht (manuelle Wahl bleibt unangetastet).
    @Published var autoStyleByApp: Bool {
        didSet { defaults.set(autoStyleByApp, forKey: Keys.autoStyleByApp) }
    }

    /// Antworten vorlesen (Zwei-Wege-Voice): liest Assistent-/Zusammenfassen-Antworten
    /// nach dem Einfügen mit einer lokalen Stimme laut vor. Standardmäßig AUS.
    @Published var speakAnswers: Bool {
        didSet { defaults.set(speakAnswers, forKey: Keys.speakAnswers) }
    }

    /// Schnelles Modell für die Live-Vorschau (klein, lädt schnell). Final bleibt large-v3-turbo.
    var previewModelPath: String {
        get { defaults.string(forKey: Keys.previewModel) ?? MurmelPaths.modelsDir.appendingPathComponent("ggml-base.bin").path }
        set { defaults.set(newValue, forKey: Keys.previewModel) }
    }

    /// Pfad zum VAD-Modell (Silero). Existiert die Datei, aktiviert der finale
    /// Transcriber Voice-Activity-Detection → weniger Halluzinationen bei Stille.
    /// Wird optional von `setup.sh` heruntergeladen.
    var vadModelPath: String {
        get { defaults.string(forKey: Keys.vadModel) ?? MurmelPaths.modelsDir.appendingPathComponent("ggml-silero-v5.1.2.bin").path }
        set { defaults.set(newValue, forKey: Keys.vadModel) }
    }

    /// Pfad zur `whisper-server`-Binary (residenter Server für die Live-Vorschau).
    var whisperServerBinaryPath: String {
        get { defaults.string(forKey: Keys.whisperServerBin) ?? Self.detectWhisperServerBinary() }
        set { defaults.set(newValue, forKey: Keys.whisperServerBin) }
    }

    /// Host des Vorschau-Servers (nur localhost — bleibt rein lokal).
    var whisperServerHost: String {
        get { defaults.string(forKey: Keys.whisperServerHost) ?? "127.0.0.1" }
        set { defaults.set(newValue, forKey: Keys.whisperServerHost) }
    }

    /// Port des Vorschau-Servers. Ungewöhnlicher Default (8771), um Kollisionen
    /// mit dem whisper.cpp-Standardport 8080 zu vermeiden.
    var whisperServerPort: Int {
        get { let v = defaults.integer(forKey: Keys.whisperServerPort); return v == 0 ? 8771 : v }
        set { defaults.set(newValue, forKey: Keys.whisperServerPort) }
    }

    // MARK: Pfade & externe Tools (mit sinnvollen Defaults)

    /// Pfad zur whisper-cli-Binary. Sucht Homebrew (arm64 + intel) ab.
    var whisperBinaryPath: String {
        get { defaults.string(forKey: Keys.whisperBin) ?? Self.detectWhisperBinary() }
        set { defaults.set(newValue, forKey: Keys.whisperBin) }
    }

    var whisperModelPath: String {
        get { defaults.string(forKey: Keys.whisperModel) ?? MurmelPaths.defaultModelFile.path }
        set { defaults.set(newValue, forKey: Keys.whisperModel) }
    }

    var ollamaBaseURL: String {
        get { defaults.string(forKey: Keys.ollamaURL) ?? "http://127.0.0.1:11434" }
        set { defaults.set(newValue, forKey: Keys.ollamaURL) }
    }

    var ollamaModel: String {
        get { defaults.string(forKey: Keys.ollamaModel) ?? "qwen2.5:3b" }
        set { defaults.set(newValue, forKey: Keys.ollamaModel) }
    }

    /// Sprachcode für Whisper (ISO 639-1).
    var language: String {
        get { defaults.string(forKey: Keys.language) ?? "de" }
        set { defaults.set(newValue, forKey: Keys.language) }
    }

    // MARK: RAG / Daten-Assistent

    /// Ordner, die der Daten-Assistent indexiert (Notizen, Code …).
    var knowledgeFolders: [String] {
        get {
            guard let data = defaults.data(forKey: Keys.knowledgeFolders),
                  let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return arr
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            defaults.set(data, forKey: Keys.knowledgeFolders)
            objectWillChange.send()
        }
    }

    /// Lokales Embedding-Modell (Ollama).
    var embedModel: String {
        get { defaults.string(forKey: Keys.embedModel) ?? "nomic-embed-text" }
        set { defaults.set(newValue, forKey: Keys.embedModel) }
    }

    /// Anzahl der Treffer, die als Kontext an Qwen gehen.
    var ragTopK: Int {
        get { let v = defaults.integer(forKey: Keys.ragTopK); return v == 0 ? 6 : v }
        set { defaults.set(newValue, forKey: Keys.ragTopK) }
    }

    /// Sinnvolle Start-Ordner für den Wissens-Assistenten — gibt von den Kandidaten
    /// NUR die zurück, die tatsächlich existieren:
    ///  - `~/Documents/Claude/Projects`
    ///  - erster Treffer unter `~/Library/CloudStorage/`, dessen Name mit "OneDrive" beginnt
    ///  - `~/Library/Mobile Documents/com~apple~CloudDocs` (iCloud Drive)
    static func defaultKnowledgeFolders() -> [String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var result: [String] = []

        // Hilfsfunktion: nur existierende Verzeichnisse aufnehmen.
        func addIfDirectory(_ url: URL) {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                result.append(url.path)
            }
        }

        // 1) ~/Documents/Claude/Projects
        addIfDirectory(home.appendingPathComponent("Documents/Claude/Projects"))

        // 2) Erster CloudStorage-Eintrag, der mit "OneDrive" beginnt.
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage")
        if let entries = try? fm.contentsOfDirectory(
            at: cloudStorage,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            let oneDrive = entries
                .filter { $0.lastPathComponent.hasPrefix("OneDrive") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .first
            if let oneDrive { addIfDirectory(oneDrive) }
        }

        // 3) iCloud Drive
        addIfDirectory(home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"))

        return result
    }

    // MARK: Init

    private init() {
        let styleRaw = defaults.string(forKey: Keys.style) ?? DictationStyle.raw.rawValue
        self.currentStyle = DictationStyle(rawValue: styleRaw) ?? .raw

        let triggerRaw = defaults.string(forKey: Keys.trigger) ?? HotkeyTrigger.fn.rawValue
        self.hotkeyTrigger = HotkeyTrigger(rawValue: triggerRaw) ?? .fn

        self.streamingEnabled = defaults.bool(forKey: Keys.streaming)

        // Auto-Modus standardmäßig AN (nur beim ersten Start, danach Nutzer-Wert respektieren).
        self.autoStyleByApp = defaults.object(forKey: Keys.autoStyleByApp) == nil
            ? true
            : defaults.bool(forKey: Keys.autoStyleByApp)

        self.speakAnswers = defaults.bool(forKey: Keys.speakAnswers)

        if #available(macOS 13.0, *) {
            self.launchAtLogin = (SMAppService.mainApp.status == .enabled)
        } else {
            self.launchAtLogin = false
        }

        // Wissens-Ordner beim allerersten Start mit sinnvollen, existierenden
        // Defaults vorbelegen. KEINE automatische Indexierung — die bleibt
        // ausschließlich nutzergetriggert.
        if knowledgeFolders.isEmpty {
            knowledgeFolders = Self.defaultKnowledgeFolders()
        }
    }

    // MARK: Pro-Modus-Instruktion (editierbar)

    /// Effektive Instruktion für einen Stil: eigene Anpassung, sonst Default.
    func instruction(for style: DictationStyle) -> String {
        defaults.string(forKey: Keys.instrPrefix + style.rawValue) ?? style.polishInstruction
    }

    /// Setzt eine eigene Instruktion. Leer oder == Default → Override entfernen.
    func setInstruction(_ text: String, for style: DictationStyle) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Keys.instrPrefix + style.rawValue
        if t.isEmpty || t == style.polishInstruction {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(t, forKey: key)
        }
        objectWillChange.send()
    }

    /// Auf den Default zurücksetzen.
    func resetInstruction(for style: DictationStyle) {
        defaults.removeObject(forKey: Keys.instrPrefix + style.rawValue)
        objectWillChange.send()
    }

    /// Ob für diesen Stil eine eigene Instruktion gesetzt ist.
    func hasCustomInstruction(for style: DictationStyle) -> Bool {
        defaults.string(forKey: Keys.instrPrefix + style.rawValue) != nil
    }

    // MARK: Login-Item

    private func applyLaunchAtLogin(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("Murmel: Login-Item konnte nicht gesetzt werden: \(error)")
        }
    }

    // MARK: Whisper-Binary-Erkennung

    static func detectWhisperBinary() -> String {
        let candidates = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "/opt/homebrew/bin/whisper-cpp",
            "/usr/local/bin/whisper-cpp"
        ]
        let fm = FileManager.default
        return candidates.first { fm.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/whisper-cli"
    }

    /// Sucht die `whisper-server`-Binary (Teil von whisper-cpp, gleiche Homebrew-Pfade).
    static func detectWhisperServerBinary() -> String {
        let candidates = [
            "/opt/homebrew/bin/whisper-server",
            "/usr/local/bin/whisper-server"
        ]
        let fm = FileManager.default
        return candidates.first { fm.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/whisper-server"
    }

    private enum Keys {
        static let style = "murmel.style"
        static let trigger = "murmel.trigger"
        static let whisperBin = "murmel.whisperBin"
        static let whisperModel = "murmel.whisperModel"
        static let ollamaURL = "murmel.ollamaURL"
        static let ollamaModel = "murmel.ollamaModel"
        static let language = "murmel.language"
        static let instrPrefix = "murmel.instr."
        static let streaming = "murmel.streaming"
        static let autoStyleByApp = "murmel.autoStyleByApp"
        static let speakAnswers = "murmel.speakAnswers"
        static let previewModel = "murmel.previewModel"
        static let vadModel = "murmel.vadModel"
        static let whisperServerBin = "murmel.whisperServerBin"
        static let whisperServerHost = "murmel.whisperServerHost"
        static let whisperServerPort = "murmel.whisperServerPort"
        static let knowledgeFolders = "murmel.knowledgeFolders"
        static let embedModel = "murmel.embedModel"
        static let ragTopK = "murmel.ragTopK"
    }
}
