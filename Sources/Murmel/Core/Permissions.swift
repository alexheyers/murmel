import AVFoundation
import AppKit
import ApplicationServices

/// Prüft & fordert die nötigen macOS-Rechte an.
enum Permissions {

    /// Mikrofon-Recht anfragen (zeigt System-Dialog beim ersten Mal).
    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    /// Ist Bedienungshilfen-Recht erteilt? (nötig für Hotkey-Tap & ⌘V).
    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Bedienungshilfen-Recht anfragen — öffnet den System-Dialog/-Bereich.
    @discardableResult
    static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Öffnet direkt die Systemeinstellungen → Datenschutz → Bedienungshilfen.
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
