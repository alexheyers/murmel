import AppKit

/// Dezente System-Sounds als Feedback für Start/Stop/Fehler.
enum Sounds {
    static func play(_ name: String) {
        NSSound(named: NSSound.Name(name))?.play()
    }

    /// Aufnahme beginnt.
    static func start() { play("Tink") }
    /// Aufnahme endet / Verarbeitung beginnt.
    static func stop() { play("Pop") }
    /// Text wurde eingefügt.
    static func done() { play("Glass") }
    /// Nichts erkannt / abgebrochen.
    static func soft() { play("Bottle") }
    /// Fehler.
    static func fail() { play("Basso") }
}
