import AppKit
import SwiftUI

/// Zustand des Live-Overlays.
enum OverlayState {
    case listening   // nimmt auf, Vorschau läuft
    case thinking    // finale Verarbeitung
    case done        // fertig eingefügt
}

/// Beobachtbares Modell für den Overlay-Text.
@MainActor
final class OverlayTextModel: ObservableObject {
    @Published var text: String = ""
    @Published var state: OverlayState = .listening
}

/// Schwebendes, klick-transparentes HUD, das während des Sprechens die
/// Live-Transkription zeigt (Streaming-Vorschau). Stiehlt keinen Fokus,
/// damit das ⌘V-Einfügen ins aktive Fenster funktioniert.
@MainActor
final class LiveOverlay {
    private var panel: NSPanel?
    private let model = OverlayTextModel()

    func show() {
        model.text = ""
        model.state = .listening
        if panel == nil { build() }
        position()
        panel?.orderFrontRegardless()
    }

    func update(_ text: String) { model.text = text }
    func setState(_ s: OverlayState) { model.state = s }
    func hide() { panel?.orderOut(nil) }

    // MARK: - Aufbau

    private func build() {
        let host = NSHostingView(rootView: OverlayView(model: model))
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 130),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.ignoresMouseEvents = true          // klick-transparent → kein Fokusklau
        p.contentView = host
        panel = p
    }

    private func position() {
        guard let p = panel, let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = p.frame.size
        let x = vf.midX - size.width / 2
        let y = vf.minY + vf.height * 0.16   // unteres Drittel
        p.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - SwiftUI-Inhalt

private struct OverlayView: View {
    @ObservedObject var model: OverlayTextModel

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
                .symbolEffect(.pulse, isActive: model.state == .listening)
            Text(model.text.isEmpty ? placeholder : model.text)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 560, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.14))
        )
        .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
        .padding(8)
    }

    private var icon: String {
        switch model.state {
        case .listening: return "waveform"
        case .thinking:  return "waveform.circle"
        case .done:      return "checkmark.circle.fill"
        }
    }
    private var color: Color {
        switch model.state {
        case .listening: return .red
        case .thinking:  return .orange
        case .done:      return .green
        }
    }
    private var placeholder: String {
        model.state == .thinking ? "Verarbeite…" : "Höre zu…"
    }
}
