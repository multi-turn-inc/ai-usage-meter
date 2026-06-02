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
        // macOS 26 workaround: when launched from inside the .app bundle (double-click),
        // the menu bar icon never appears. Hand off to a standalone copy via LaunchAgent
        // and quit. Skipped in blog-render mode (run from the standalone CLI binary).
        if !isBlogRenderMode, LaunchAgentRedirect.shouldRedirect() {
            if LaunchAgentRedirect.redirectAndStart() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NSApp.terminate(nil)
                }
                return
            }
            // Standalone launch failed — fall through and run in-bundle (degraded, but visible).
        }

        let controller = MenuBarPanelController(
            title: "Token Burn",
            appState: appState,
            themeManager: ThemeManager.shared
        )
        menuBarController = controller

        // Blog render mode: AIM_BLOG_RENDER=1 ./AIUsageMeter
        if isBlogRenderMode {
            Task { @MainActor in
                // Wait for data to load
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                BlogRenderer.renderAll(appState: appState)
                NSApp.terminate(nil)
            }
        }
    }

    private var isBlogRenderMode: Bool {
        ProcessInfo.processInfo.environment["AIM_BLOG_RENDER"] != nil
    }
}
