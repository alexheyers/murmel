import Foundation
import CoreGraphics
import ApplicationServices

/// Globaler Push-to-talk-Hotkey via CGEventTap.
///
/// Lauscht systemweit auf `flagsChanged`-Events. Sowohl die fn-Taste (🌐)
/// als auch die rechte ⌥-Taste erzeugen `flagsChanged`-Events (kein klares
/// keyDown/keyUp). Deshalb wird der Druck-Zustand über die Modifier-Flags
/// bzw. den Keycode rekonstruiert und intern als Zustandsmaschine geführt:
/// Flanke false→true → `onPress`, Flanke true→false → `onRelease`.
///
/// Voraussetzung: Die App braucht das Bedienungshilfen-Recht
/// (Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen).
final class HotkeyMonitor: HotkeyMonitoring {

    // MARK: - Öffentliche Schnittstelle (HotkeyMonitoring)

    /// Wird bei der Druck-Flanke (Taste neu gedrückt) aufgerufen — auf dem Main-Thread.
    var onPress: (() -> Void)?
    /// Wird bei der Loslass-Flanke (Taste neu losgelassen) aufgerufen — auf dem Main-Thread.
    var onRelease: (() -> Void)?
    /// Welche Taste lauschen. Kann zur Laufzeit gewechselt werden.
    /// Beim Wechsel wird der gehaltene Zustand zurückgesetzt, damit keine
    /// hängende „gedrückt"-Flanke aus einem alten Trigger übrig bleibt.
    var trigger: HotkeyTrigger {
        didSet {
            if oldValue != trigger {
                isPressed = false
            }
        }
    }

    // MARK: - Interner Zustand

    /// Der laufende Event-Tap (nil, solange nicht gestartet).
    private var eventTap: CFMachPort?
    /// Die RunLoopSource des Taps (zum sauberen Entfernen beim Stop).
    private var runLoopSource: CFRunLoopSource?
    /// Aktueller Druck-Zustand der Trigger-Taste — Basis für die Flankenerkennung.
    private var isPressed = false

    /// Keycode der rechten ⌥-Taste (kVK_RightOption). Die linke ⌥ ist 58 und wird ignoriert.
    private static let rightOptionKeycode: Int64 = 61

    // MARK: - Init

    init(trigger: HotkeyTrigger) {
        self.trigger = trigger
    }

    deinit {
        stop()
    }

    // MARK: - Start / Stop

    /// Startet das Event-Tap.
    /// - Returns: `false`, wenn das Bedienungshilfen-Recht fehlt oder der Tap
    ///   nicht erstellt werden konnte; sonst `true`.
    func start() -> Bool {
        // Bereits laufend? → idempotent als Erfolg behandeln.
        if eventTap != nil {
            return true
        }

        // Ohne Bedienungshilfen-Recht kann der Tap keine globalen Events lesen.
        guard AXIsProcessTrusted() else {
            return false
        }

        // Nur an flagsChanged-Events interessiert (fn + rechte ⌥ erzeugen beide solche).
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)

        // self als opaken Zeiger an den C-Callback durchreichen (kein Capturing-Closure
        // möglich, da CGEventTapCallBack ein reiner C-Funktionspointer ist).
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyEventCallback,
            userInfo: refcon
        ) else {
            // Tap-Erstellung gescheitert (z.B. Recht zwischenzeitlich entzogen).
            return false
        }

        // RunLoopSource erstellen und an die Main-RunLoop hängen.
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        self.isPressed = false

        return true
    }

    /// Stoppt das Event-Tap und gibt alle Ressourcen frei.
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isPressed = false
    }

    // MARK: - Event-Verarbeitung (vom C-Callback aufgerufen)

    /// Wertet ein einzelnes `flagsChanged`-Event aus und feuert ggf. die Callbacks.
    /// Läuft auf dem RunLoop-Thread; die Callbacks werden daher auf Main dispatcht.
    fileprivate func handle(event: CGEvent) {
        let isDown: Bool

        switch trigger {
        case .fn:
            // fn / 🌐 spiegelt sich direkt im Secondary-Fn-Flag.
            isDown = event.flags.contains(.maskSecondaryFn)

        case .rightOption:
            // Nur die rechte ⌥ reagiert (Keycode 61). Die linke ⌥ (58) wird ignoriert.
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            guard keycode == Self.rightOptionKeycode else {
                return
            }
            // ⌥ gedrückt → Alternate-Flag gesetzt.
            isDown = event.flags.contains(.maskAlternate)
        }

        // Flankenerkennung: nur bei echtem Zustandswechsel Callbacks feuern.
        if isDown, !isPressed {
            isPressed = true
            let cb = onPress
            DispatchQueue.main.async { cb?() }
        } else if !isDown, isPressed {
            isPressed = false
            let cb = onRelease
            DispatchQueue.main.async { cb?() }
        }
    }
}

// MARK: - C-Callback (top-level, ohne Capture)

/// CGEventTapCallBack: muss ein reiner C-Funktionspointer sein (kein Capturing-Closure).
/// Holt die HotkeyMonitor-Instanz aus dem refcon zurück und reicht das Event weiter.
/// Gibt das Event unverändert zurück (`passUnretained`), damit das System die Taste
/// weiterhin normal verarbeitet.
private func hotkeyEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let refcon = refcon {
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        monitor.handle(event: event)
    }
    // Event unverändert durchreichen.
    return Unmanaged.passUnretained(event)
}
