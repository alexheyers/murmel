import Foundation

/// Ordnet der aktiven (frontmost) App einen passenden Diktat-Stil zu.
///
/// Wird nur im Auto-Modus genutzt und auch dann nur, wenn der Nutzer aktuell auf
/// dem Standard-Stil `.raw` steht — eine bewusste manuelle Stilwahl wird NIE
/// überschrieben. Liefert `nil` für unbekannte Apps (Aufrufer fällt dann auf
/// `.raw` zurück).
///
/// Erkennung: zuerst über die `bundleId` (case-insensitive), als Fallback über
/// den (kleingeschriebenen) App-Namen, der ein Stichwort enthält.
enum AppStyleMapper {

    /// Liefert den passenden Stil für eine App oder `nil`, wenn nichts zutrifft.
    static func style(forBundleId bundleId: String?, name: String?) -> DictationStyle? {
        // 1. Bundle-Identifier (case-insensitive) — die zuverlässigste Quelle.
        if let id = bundleId?.lowercased() {
            switch id {
            case "com.apple.terminal",
                 "com.googlecode.iterm2",
                 "com.mitchellh.ghostty",
                 "dev.warp.warp-stable",
                 "com.microsoft.vscode",
                 "com.apple.dt.xcode":
                return .raw
            case "com.apple.mail",
                 "com.microsoft.outlook",
                 "com.readdle.smartemail-mac":
                return .email
            // Apple Notes ABSICHTLICH NICHT → Brainstorming: dort will man meist
            // wörtliche Notizen, kein zu Stichpunkten umgeschriebenes (und langsames) Diktat.
            case "notion.id",
                 "md.obsidian",
                 "net.shinyfrog.bear":
                return .brainstorm
            default:
                break
            }
        }

        // 2. Fallback: App-Name enthält ein Stichwort (kleingeschrieben).
        if let lower = name?.lowercased() {
            if lower.contains("terminal") || lower.contains("iterm") || lower.contains("ghostty")
                || lower.contains("warp") || lower.contains("code") || lower.contains("xcode") {
                return .raw
            }
            if lower.contains("mail") || lower.contains("outlook") {
                return .email
            }
            if lower.contains("notion") || lower.contains("obsidian") {
                return .brainstorm
            }
        }

        return nil
    }
}
