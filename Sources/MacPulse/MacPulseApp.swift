// App entry point and window/menu wiring.
import SwiftUI
import MacPulseCore
import MacPulseUI

@main
struct MacPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: MetricsStore
    @State private var insights: InsightsStore

    init() {
        let store = MetricsStore()
        _store = State(initialValue: store)
        _insights = State(initialValue: InsightsStore(metrics: store))
    }

    var body: some Scene {
        WindowGroup(MacPulseInfo.appName, id: "dashboard") {
            DashboardView(store: store, insights: insights)
                .onAppear {
                    store.start()
                    insights.start()
                }
        }
        .defaultSize(width: 1040, height: 940)
        .commands {
            AboutCommands()
        }

        Window("About \(MacPulseInfo.appName)", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
    }
}

/// A single-window utility: quit when the dashboard closes instead of sampling in the background.
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Replaces the default "About MacPulse" menu item so it opens our About window.
private struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(MacPulseInfo.appName)") {
                openWindow(id: "about")
            }
        }
    }
}
