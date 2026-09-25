import AppKit
import SwiftUI
import AIUsageMeterCore

/// Renders SwiftUI views to PNG files for blog posts.
///
/// The output directory is chosen by (in order):
///   1. `AIM_BLOG_RENDER_OUTPUT_DIR` if set (expands `~`)
///   2. `<tmp>/token-burn-blog-renders` — never embeds a personal path in the binary
@MainActor
enum BlogRenderer {
    private static var outputDir: URL {
        if let raw = ProcessInfo.processInfo.environment["AIM_BLOG_RENDER_OUTPUT_DIR"],
           !raw.isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("token-burn-blog-renders", isDirectory: true)
    }

    /// Fills the board with made-up plans, so screenshots show every state —
    /// a pick, a plan to return to, a blocked seat, a workspace to connect —
    /// without a single real account, org or email in them.
    static func installFixture(into appState: AppState) {
        let now = Date()
        let hour: TimeInterval = 3600
        let day: TimeInterval = 86_400

        func window(_ label: String, _ used: Double, resetsIn: TimeInterval?, role: UsageWindow.Role,
                    seconds: Double?) -> UsageWindow {
            UsageWindow(label: label, percent: used, resetsAt: resetsIn.map { now.addingTimeInterval($0) },
                        isCritical: used >= 100, role: role, windowSeconds: seconds)
        }
        func claude(_ five: Double, _ fiveIn: TimeInterval?, _ seven: Double, _ sevenIn: TimeInterval) -> [UsageWindow] {
            [window("5h", five, resetsIn: fiveIn, role: .session, seconds: 5 * hour),
             window("7d", seven, resetsIn: sevenIn, role: .weekly, seconds: 7 * day)]
        }
        func model(_ service: ServiceType, id: String, org: String, email: String, plan: String,
                   windows: [UsageWindow], workspaces: [ChatGPTWorkspace] = [],
                   isDefault: Bool = false) -> ServiceViewModel {
            let person = email.split(separator: "@").first.map(String.init) ?? email
            let account = ProviderAccount(
                id: "\(service.rawValue.lowercased()):fixture:\(id)", service: service, email: email,
                organizationName: org, identityKey: id, source: .file(path: "/dev/null"),
                isDefault: isDefault, configDir: "/Users/me/Library/Application Support/TokenBurn/accounts/\(id)",
                planName: plan, personKey: person, evidenceKey: "\(person)|\(id)")
            var usage = UsageData(
                tokensUsed: 0, tokensLimit: 0, inputTokens: nil, outputTokens: nil,
                periodStart: now, periodEnd: now, resetDate: nil, sevenDayResetDate: nil,
                currentCost: nil, projectedCost: nil, currency: "USD", tier: plan, lastUpdated: now,
                fiveHourUsage: windows.first?.percent, sevenDayUsage: windows.dropFirst().first?.percent,
                windows: windows)
            usage.plan = PlanIdentity(key: "\(person)|\(id)", personKey: person, email: email,
                                      orgName: org, planName: plan)
            usage.workspaces = workspaces
            let row = ServiceViewModel(config: ServiceConfig(serviceType: service, isEnabled: true),
                                       usage: usage, account: account)
            row.hasLoaded = true
            return row
        }

        let workspaces = [
            ChatGPTWorkspace(id: "acme", name: "Acme", isPersonal: false, planType: "team"),
            ChatGPTWorkspace(id: "side", name: "Side Project", isPersonal: false, planType: "team"),
            ChatGPTWorkspace(id: "me", name: nil, isPersonal: true, planType: "pro"),
        ]
        appState.services = [
            model(.claude, id: "personal", org: "Personal", email: "me@example.com", plan: "Max 20x",
                  windows: claude(34, 2 * hour + 10 * 60, 22, 5 * day + 3 * hour), isDefault: true),
            model(.claude, id: "acme", org: "Acme", email: "me@example.com", plan: "Team 5x",
                  windows: claude(8, 4 * hour, 71, 14 * hour)),
            model(.claude, id: "studio", org: "Studio", email: "jo@example.com", plan: "Team",
                  windows: claude(100, hour + 20 * 60, 55, day + 2 * hour)),
            model(.codex, id: "acme", org: "Acme", email: "me@example.com", plan: "Business",
                  windows: [window("7d", 60, resetsIn: 6 * day + 19 * hour, role: .weekly, seconds: 7 * day),
                            window("credits", 95, resetsIn: 5 * day + 12 * hour, role: .spend, seconds: nil)],
                  workspaces: workspaces),
            model(.codex, id: "me", org: "Personal", email: "me@example.com", plan: "Pro",
                  windows: [window("7d", 18, resetsIn: 2 * day + 4 * hour, role: .weekly, seconds: 7 * day)],
                  workspaces: workspaces, isDefault: true),
        ]
        appState.lastRefreshDate = now.addingTimeInterval(-42)
        appState.updateAdvice(now: now)
    }

    /// Tall enough for the whole board by default; `AIM_BLOG_RENDER_HEIGHT` overrides.
    private static var panelHeight: CGFloat {
        CGFloat(Double(ProcessInfo.processInfo.environment["AIM_BLOG_RENDER_HEIGHT"] ?? "") ?? 700)
    }

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
            width: 300, height: panelHeight,
            to: dir.appendingPathComponent("panel.png")
        )

        renderView(
            ContentView(appState: appState)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(nsColor: .windowBackgroundColor))
                ),
            width: 300, height: panelHeight,
            to: dir.appendingPathComponent("panel-dark.png"),
            dark: true
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

    private static func renderView<V: View>(_ view: V, width: CGFloat, height: CGFloat, to url: URL,
                                            dark: Bool = false) {
        let wrapped = view
            .frame(width: width, height: height)
            .environment(\.colorScheme, dark ? .dark : .light)

        let hostingView = NSHostingView(rootView: wrapped)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hostingView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
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
