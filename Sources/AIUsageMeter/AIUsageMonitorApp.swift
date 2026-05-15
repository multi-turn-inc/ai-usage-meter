import SwiftUI
import AppKit

@main
struct AIUsageMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) { }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    private var menuBarController: MenuBarPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MenuBarPanelController(
            title: "Token Burn",
            appState: appState,
            themeManager: ThemeManager.shared
        )
        menuBarController = controller

        // Blog render mode: AIM_BLOG_RENDER=1 ./AIUsageMeter
        if ProcessInfo.processInfo.environment["AIM_BLOG_RENDER"] != nil {
            Task { @MainActor in
                // Wait for data to load
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                BlogRenderer.renderAll(appState: appState)
                NSApp.terminate(nil)
            }
        }
    }
}
