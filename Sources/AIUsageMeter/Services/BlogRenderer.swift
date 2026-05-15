import AppKit
import SwiftUI

/// Renders SwiftUI views to PNG files for blog posts.
@MainActor
enum BlogRenderer {
    private static let outputDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("_PARA/2_Areas/🏢_멀티턴_운영/ZUZU/docs/multi-turn-homepage/public/blog/figures/token-burn")

    static func renderAll(appState: AppState) {
        let dir = outputDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        renderView(
            ContentView(appState: appState)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.ultraThinMaterial)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color(nsColor: .windowBackgroundColor))
                        )
                ),
            width: 300, height: 600,
            to: dir.appendingPathComponent("panel.png")
        )

        renderView(
            menuBarIconView(appState: appState),
            width: 200, height: 40,
            to: dir.appendingPathComponent("menubar.png")
        )

        print("📸 Blog renders saved to \(dir.path)")
    }

    private static func menuBarIconView(appState: AppState) -> some View {
        HStack(spacing: 4) {
            Image(nsImage: MenuBarIconRenderer.render(
                appState: appState,
                themeManager: ThemeManager.shared
            ))
        }
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private static func renderView<V: View>(_ view: V, width: CGFloat, height: CGFloat, to url: URL) {
        let wrapped = view
            .frame(width: width, height: height)
            .environment(\.colorScheme, .light)

        let hostingView = NSHostingView(rootView: wrapped)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        hostingView.wantsLayer = true
        hostingView.layoutSubtreeIfNeeded()

        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            print("❌ Failed to create bitmap for \(url.lastPathComponent)")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)

        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("❌ Failed to encode PNG for \(url.lastPathComponent)")
            return
        }

        do {
            try data.write(to: url, options: .atomic)
            print("📸 Rendered: \(url.lastPathComponent) (\(Int(width))x\(Int(height)))")
        } catch {
            print("❌ Write failed: \(error)")
        }
    }
}
