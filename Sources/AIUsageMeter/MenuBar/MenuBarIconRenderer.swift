import AppKit
import SwiftUI
import AIUsageMeterCore

@MainActor
enum MenuBarIconRenderer {

    /// The load cell is only 22 px high; sub-percent changes cannot alter a
    /// rendered pixel and should not invalidate the cached icon.
    static func displayedLoad(_ value: Double) -> Double { value.rounded() }

    static func render(appState: AppState, themeManager: ThemeManager) -> NSImage {
        // One cell per provider, not per account. With several logins per
        // provider the bar would otherwise grow without bound, so each cell
        // shows that provider's most-constrained account — the one about to
        // run out is what you need to see at a glance. The panel breaks the
        // accounts out individually.
        let services = mostConstrainedPerService(appState.services.filter { $0.config.isEnabled })
        guard !services.isEmpty else {
            // Show a placeholder icon when no services are enabled
            let img = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { rect in
                NSColor.secondaryLabelColor.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 3), xRadius: 3, yRadius: 3).fill()
                return true
            }
            img.isTemplate = true
            return img
        }

        let serviceWidth: CGFloat = 38
        let spacing: CGFloat = 6
        // Optional system-load meter cell after the services.
        let showLoad = AppDefaults.userDefaults.object(forKey: "loadTabEnabled") as? Bool ?? true
        let cellCount = services.count + (showLoad ? 1 : 0)
        let totalWidth = CGFloat(cellCount) * serviceWidth + CGFloat(cellCount - 1) * spacing
        let height: CGFloat = 22

        let snapshot = services.map { service -> ServiceSnapshot in
            return ServiceSnapshot(
                brandColor: service.config.serviceType.brandColor.nsColor,
                serviceType: service.config.serviceType,
                fiveHourUsage: service.fiveHourUsage,
                sevenDayUsage: service.sevenDayUsage,
                usagePercentage: service.usagePercentage,
                isConsuming: service.isConsuming
            )
        }

        // Snapshot load values up front (render closure runs on the same actor).
        let load = SystemLoadMonitor.shared
        let loadSnapshot: (cpu: Double, gpu: Double, ram: Double)? = showLoad ? (
            displayedLoad(load.cpu), displayedLoad(load.gpu), displayedLoad(load.ram)
        ) : nil

        let image = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { _ in
            // `NSAppearance.current` is deprecated (macOS 12+); use the
            // drawing appearance active for this image draw pass instead.
            let dark: Bool = {
                switch NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) {
                case .darkAqua: return true
                default: return false
                }
            }()

            var x: CGFloat = 0
            for service in snapshot {
                drawMeter(at: x, service: service, dark: dark, width: serviceWidth, height: height)
                x += serviceWidth + spacing
            }
            if let loadSnapshot {
                drawLoadMeter(at: x, cpu: loadSnapshot.cpu, gpu: loadSnapshot.gpu, ram: loadSnapshot.ram,
                              dark: dark, width: serviceWidth, height: height)
            }
            return true
        }

        image.isTemplate = false
        return image
    }

    /// Picks, for each provider, the account with the least headroom left —
    /// highest usage across its 5-hour and 7-day windows. Provider order stays
    /// stable so the icon doesn't reshuffle between refreshes.
    static func mostConstrainedPerService(_ services: [ServiceViewModel]) -> [ServiceViewModel] {
        var byType: [ServiceType: ServiceViewModel] = [:]
        for service in services {
            let type = service.config.serviceType
            // An explicit choice wins: the automatic "busiest account" rule is a
            // reasonable default but it reassigns itself as usage moves, so the
            // cell would silently start reporting a different login.
            if let account = service.account, AccountRegistry.shared.isPinned(account) {
                byType[type] = service
                continue
            }
            guard let incumbent = byType[type] else {
                byType[type] = service
                continue
            }
            if let pinnedAccount = incumbent.account, AccountRegistry.shared.isPinned(pinnedAccount) {
                continue
            }
            if pressure(of: service) > pressure(of: incumbent) {
                byType[type] = service
            }
        }
        return ServiceType.allCases.compactMap { byType[$0] }
    }

    private static func pressure(of service: ServiceViewModel) -> Double {
        max(service.fiveHourUsage ?? service.usagePercentage,
            service.sevenDayUsage ?? 0)
    }

    private struct ServiceSnapshot {
        let brandColor: NSColor
        let serviceType: ServiceType
        let fiveHourUsage: Double?
        let sevenDayUsage: Double?
        let usagePercentage: Double
        let isConsuming: Bool
    }

    private static func drawMeter(
        at x: CGFloat,
        service: ServiceSnapshot,
        dark: Bool,
        width: CGFloat,
        height: CGFloat
    ) {
        let color = service.brandColor
        let labelColor = dark ? NSColor.white : NSColor.black
        let borderColor = dark ? NSColor.white.withAlphaComponent(0.55) : NSColor.black.withAlphaComponent(0.40)
        let emptyBarColor = dark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.10)

        let fiveHourRemaining = max(0, 100.0 - (service.fiveHourUsage ?? service.usagePercentage)) / 100.0
        let sevenDayRemaining = max(0, 100.0 - (service.sevenDayUsage ?? service.usagePercentage)) / 100.0

        // Consuming is a state indicator. Keep it static so the menu-bar icon is only
        // rendered when an input changes; a timer-driven heartbeat made the app redraw
        // the entire icon 12 times per second while an agent was active.
        let borderPulse: CGFloat = service.isConsuming ? 0.22 : 0
        let activeBorderColor = borderColor.blended(withFraction: borderPulse, of: color) ?? borderColor
        let fillAlpha: CGFloat = service.isConsuming ? 0.86 : 1.0

        let label: String
        switch service.serviceType {
        case .claude: label = "Claude"
        case .codex: label = "Codex"
        case .gemini: label = "Gemini"
        }

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .medium),
            .foregroundColor: labelColor,
        ]

        let labelSize = label.size(withAttributes: labelAttrs)
        NSAttributedString(string: label, attributes: labelAttrs)
            .draw(at: NSPoint(x: x + (width - labelSize.width) / 2, y: height - 9))

        let barCount = 10
        let barAreaWidth = width - 4
        let barWidth: CGFloat = (barAreaWidth - CGFloat(barCount - 1) * 1) / CGFloat(barCount)
        let maxBarHeight: CGFloat = 10
        let barY: CGFloat = 2

        let barHeight = maxBarHeight * max(0.2, CGFloat(sevenDayRemaining))

        let frameRect = NSRect(x: x + 1, y: barY - 1, width: barAreaWidth + 2, height: maxBarHeight + 2)
        let framePath = NSBezierPath(roundedRect: frameRect, xRadius: 2, yRadius: 2)

        NSColor.black.withAlphaComponent(0.28).setFill()
        framePath.fill()

        activeBorderColor.setStroke()
        framePath.lineWidth = 0.75
        framePath.stroke()

        for i in 0..<barCount {
            let barX = x + 2 + CGFloat(i) * (barWidth + 1)
            let fillRect = NSRect(x: barX, y: barY, width: barWidth, height: barHeight)

            let barPosition = CGFloat(i + 1) / CGFloat(barCount)
            let shouldFill = barPosition <= CGFloat(fiveHourRemaining) + 0.05

            if shouldFill {
                let fillColor = color.withAlphaComponent(fillAlpha)
                fillColor.setFill()
            } else {
                emptyBarColor.setFill()
            }

            NSBezierPath(rect: fillRect).fill()
        }
    }

    /// System-load meter, same grammar as the service meters: horizontal fill = CPU,
    /// bar height = GPU, color = RAM pressure (green→red).
    private static func drawLoadMeter(
        at x: CGFloat,
        cpu: Double, gpu: Double, ram: Double,
        dark: Bool,
        width: CGFloat,
        height: CGFloat
    ) {
        let color = SystemLoadMonitor.ramColor(ram).nsColor
        let labelColor = dark ? NSColor.white : NSColor.black
        let borderColor = dark ? NSColor.white.withAlphaComponent(0.55) : NSColor.black.withAlphaComponent(0.40)
        let emptyBarColor = dark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.10)

        let cpuFrac = max(0, min(1, cpu / 100))
        let gpuFrac = max(0, min(1, gpu / 100))

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .medium),
            .foregroundColor: labelColor,
        ]
        let label = "Load"
        let labelSize = label.size(withAttributes: labelAttrs)
        NSAttributedString(string: label, attributes: labelAttrs)
            .draw(at: NSPoint(x: x + (width - labelSize.width) / 2, y: height - 9))

        let barCount = 10
        let barAreaWidth = width - 4
        let barWidth: CGFloat = (barAreaWidth - CGFloat(barCount - 1) * 1) / CGFloat(barCount)
        let maxBarHeight: CGFloat = 10
        let barY: CGFloat = 2
        let barHeight = maxBarHeight * max(0.2, CGFloat(gpuFrac))   // GPU → height

        let frameRect = NSRect(x: x + 1, y: barY - 1, width: barAreaWidth + 2, height: maxBarHeight + 2)
        let framePath = NSBezierPath(roundedRect: frameRect, xRadius: 2, yRadius: 2)
        NSColor.black.withAlphaComponent(0.28).setFill()
        framePath.fill()
        borderColor.setStroke()
        framePath.lineWidth = 0.75
        framePath.stroke()

        for i in 0..<barCount {
            let barX = x + 2 + CGFloat(i) * (barWidth + 1)
            let fillRect = NSRect(x: barX, y: barY, width: barWidth, height: barHeight)
            let barPosition = CGFloat(i + 1) / CGFloat(barCount)
            if barPosition <= CGFloat(cpuFrac) + 0.05 {   // CPU → fill
                color.setFill()
            } else {
                emptyBarColor.setFill()
            }
            NSBezierPath(rect: fillRect).fill()
        }
    }
}

extension Color {
    var nsColor: NSColor { NSColor(self) }
}
