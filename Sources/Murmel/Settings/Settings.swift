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

    // MARK: Init

    private init() {
        let styleRaw = defaults.string(forKey: Keys.style) ?? DictationStyle.claudePrompt.rawValue
        self.currentStyle = DictationStyle(rawValue: styleRaw) ?? .claudePrompt

        let triggerRaw = defaults.string(forKey: Keys.trigger) ?? HotkeyTrigger.fn.rawValue
        self.hotkeyTrigger = HotkeyTrigger(rawValue: triggerRaw) ?? .fn

        if #available(macOS 13.0, *) {
            self.launchAtLogin = (SMAppService.mainApp.status == .enabled)
        } else {
            self.launchAtLogin = false
        }
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

    private enum Keys {
        static let style = "murmel.style"
        static let trigger = "murmel.trigger"
        static let whisperBin = "murmel.whisperBin"
        static let whisperModel = "murmel.whisperModel"
        static let ollamaURL = "murmel.ollamaURL"
        static let ollamaModel = "murmel.ollamaModel"
        static let language = "murmel.language"
    }
}
