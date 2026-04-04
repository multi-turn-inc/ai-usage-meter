import SwiftUI
import AppKit

struct MenuBarTheme {
    let label: NSColor
    let border: NSColor
    let emptyBar: NSColor
}

struct AppTheme {
    let background: Color
    let border: Color
    let divider: Color
    let track: Color
    let trackSubtle: Color
    let controlFill: Color
    let controlStroke: Color
    let shadow: Color
    let statusSuccess: Color
    let statusCaution: Color
    let statusWarning: Color
    let statusDanger: Color
    let statusNeutral: Color
    let glassTint: Color?
    let menuBar: MenuBarTheme

    static func system(scheme: ColorScheme) -> AppTheme {
        let background = Color(nsColor: .windowBackgroundColor)
        let separator = Color(nsColor: .separatorColor)
        let controlBg = Color(nsColor: .controlBackgroundColor)

        return AppTheme(
            background: background,
            border: separator,
            divider: separator,
            track: separator.opacity(scheme == .dark ? 0.75 : 0.55),
            trackSubtle: separator.opacity(scheme == .dark ? 0.45 : 0.35),
            controlFill: controlBg.opacity(scheme == .dark ? 0.65 : 0.75),
            controlStroke: separator.opacity(scheme == .dark ? 0.90 : 0.80),
            shadow: Color.black.opacity(scheme == .dark ? 0.10 : 0.06),
            statusSuccess: Color(nsColor: .systemGreen),
            statusCaution: Color(nsColor: .systemYellow),
            statusWarning: Color(nsColor: .systemOrange),
            statusDanger: Color(nsColor: .systemRed),
            statusNeutral: Color(nsColor: .secondaryLabelColor),
            glassTint: nil,
            menuBar: menuBarTheme(scheme: scheme)
        )
    }

    private static func menuBarTheme(scheme: ColorScheme) -> MenuBarTheme {
        switch scheme {
        case .dark:
            return MenuBarTheme(
                label: NSColor.white.withAlphaComponent(0.90),
                border: NSColor.white.withAlphaComponent(0.28),
                emptyBar: NSColor.white.withAlphaComponent(0.08)
            )
        case .light:
            return MenuBarTheme(
                label: NSColor.black.withAlphaComponent(0.78),
                border: NSColor.black.withAlphaComponent(0.16),
                emptyBar: NSColor.black.withAlphaComponent(0.06)
            )
        @unknown default:
            return MenuBarTheme(
                label: NSColor.white.withAlphaComponent(0.90),
                border: NSColor.white.withAlphaComponent(0.28),
                emptyBar: NSColor.white.withAlphaComponent(0.08)
            )
        }
    }
}

extension View {
    func premiumCard(cornerRadius: CGFloat = 16) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(
                shape.fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            )
            .overlay(
                shape.stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
            )
            .clipShape(shape)
            .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
    }

    func premiumPill(cornerRadius: CGFloat = 10) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(
                shape.fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
            )
            .overlay(
                shape.stroke(Color(nsColor: .separatorColor).opacity(0.25), lineWidth: 0.5)
            )
            .clipShape(shape)
    }
}

@MainActor
@Observable
final class ThemeManager {
    static let shared = ThemeManager()

    var current: AppTheme {
        AppTheme.system(scheme: effectiveScheme)
    }

    var effectiveScheme: ColorScheme {
        systemIsDark ? .dark : .light
    }

    private var systemIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private init() {}
}
