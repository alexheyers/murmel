import SwiftUI
import AppKit

@main
struct MurmelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(coordinator: appDelegate.coordinator)
        } label: {
            MenuBarLabel(coordinator: appDelegate.coordinator)
        }
        .menuBarExtraStyle(.window)

        // Verwaltungsfenster (Verlauf + Wörterbuch), aus dem Menü geöffnet.
        Window("Murmel", id: "murmel-main") {
            ManagementView(coordinator: appDelegate.coordinator)
        }
        .windowResizability(.contentSize)
    }
}

/// Hält den Coordinator und aktiviert ihn beim Start (vor dem ersten Menü-Klick).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menubar-only: kein Dock-Icon.
        NSApp.setActivationPolicy(.accessory)
        coordinator.activate()
    }
}

/// Das Menubar-Icon, das sich je nach Zustand ändert.
struct MenuBarLabel: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        Image(systemName: symbol)
    }

    private var symbol: String {
        switch coordinator.phase {
        case .idle:         return "mic"
        case .recording:    return "mic.fill"
        case .transcribing, .polishing, .inserting: return "waveform"
        case .error:        return "exclamationmark.triangle"
        }
    }
}
