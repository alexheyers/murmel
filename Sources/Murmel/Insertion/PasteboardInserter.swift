import AppKit
import CoreGraphics

/// Fügt Text ins aktive Fenster ein, indem der Text über die Zwischenablage
/// transportiert und anschließend ein synthetisches ⌘V ausgelöst wird.
///
/// Strategie:
/// 1. Alten Zwischenablage-Inhalt sichern.
/// 2. Neuen Text in die Zwischenablage schreiben.
/// 3. Kurz warten, damit die Zwischenablage garantiert "steht".
/// 4. ⌘V via CGEvent synthetisieren.
/// 5. Nach kurzer Wartezeit den alten Zwischenablage-Inhalt wiederherstellen.
///
/// Hinweis: ⌘V-Synthese setzt das Bedienungshilfen-Recht (Accessibility) voraus.
/// Diese Prüfung erfolgt an anderer Stelle — hier wird das Event einfach gepostet.
final class PasteboardInserter: TextInserting {

    /// Virtueller Keycode für die Taste 'v' (ANSI-Layout).
    private let keyCodeV: CGKeyCode = 9

    /// Wartezeit, damit die Zwischenablage nach dem Setzen sicher verfügbar ist.
    private let pasteDelay: TimeInterval = 0.05   // ~50 ms

    /// Wartezeit nach dem ⌘V, bevor der alte Inhalt zurückgeschrieben wird.
    private let restoreDelay: TimeInterval = 0.15 // ~150 ms

    init() {}

    // MARK: - TextInserting

    func insert(_ text: String) {
        // Der gesamte Ablauf berührt NSPasteboard und CGEvent — beides gehört
        // auf den Main-Thread. Idempotent absichern: wenn wir schon dort sind,
        // direkt ausführen, sonst auf den Main-Thread umleiten.
        if Thread.isMainThread {
            performInsert(text)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.performInsert(text)
            }
        }
    }

    // MARK: - Interne Umsetzung (immer auf dem Main-Thread)

    private func performInsert(_ text: String) {
        let pasteboard = NSPasteboard.general

        // 1. Aktuellen Zwischenablage-Inhalt sichern (soweit vorhanden).
        let savedContent = pasteboard.string(forType: .string)

        // 2. Neuen Text in die Zwischenablage schreiben.
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // 3. Kurz warten, dann ⌘V auslösen — ohne den Thread zu blockieren.
        DispatchQueue.main.asyncAfter(deadline: .now() + pasteDelay) { [weak self] in
            guard let self else { return }
            self.synthesizePasteShortcut()

            // 5. Nach kurzer Verzögerung den vorherigen Inhalt best effort
            //    wiederherstellen.
            DispatchQueue.main.asyncAfter(deadline: .now() + self.restoreDelay) {
                self.restorePasteboard(savedContent)
            }
        }
    }

    /// Synthetisiert ein ⌘V (keyDown + keyUp) und postet es an den HID-Event-Tap.
    private func synthesizePasteShortcut() {
        // Eigene Event-Source — robuster als nil, da sie ein konsistentes
        // Status-Modell für die synthetischen Events liefert.
        let source = CGEventSource(stateID: .combinedSessionState)

        // 4. keyDown + keyUp für 'v' mit gedrückter ⌘-Taste erzeugen.
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false)
        else {
            // Konnte das Event nicht erstellen — leise abbrechen (Fallback).
            return
        }

        // ⌘-Flag setzen, damit aus 'v' ein ⌘V wird.
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        // An den HID-Event-Tap posten, sodass das System das ⌘V wie eine
        // echte Tastatureingabe behandelt.
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    /// Schreibt den zuvor gesicherten Inhalt zurück (best effort).
    private func restorePasteboard(_ savedContent: String?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // Nur zurückschreiben, wenn es vorher überhaupt einen String-Inhalt gab.
        if let savedContent {
            pasteboard.setString(savedContent, forType: .string)
        }
    }
}
