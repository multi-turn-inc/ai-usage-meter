import AppKit
import SwiftUI
import AIUsageMeterCore

@MainActor
enum MenuBarIconRenderer {

    /// How far into its pulse a consuming cell is, 0…1.
    ///
    /// A soft double beat, wide enough to read at the 5 Hz the menu bar
    /// animates at — the old 12 Hz heartbeat redrew the whole icon a dozen
    /// times a second. Quantized to quarters, so most ticks — including the
    /// whole rest between beats — produce an identical frame the render gate
    /// skips.
    static func beat(for service: ServiceViewModel, at date: Date) -> Double {
        guard service.isConsuming else { return 0 }
        let remaining = max(
            max(0, 100.0 - (service.fiveHourUsage ?? service.usagePercentage)),
            max(0, 100.0 - (service.sevenDayUsage ?? service.usagePercentage))
        ) / 100.0
        // Less headroom, faster pulse — the cue the old heartbeat gave.
        let period = 1.2 + remaining * 1.2
        let offset: TimeInterval = service.config.serviceType == .codex ? 0.37 : 0
        let phase = (date.timeIntervalSinceReferenceDate + offset)
            .truncatingRemainder(dividingBy: period) / period
        let value: Double
        switch phase {
        case ..<0.25: value = sin(phase / 0.25 * .pi)
        case 0.35..<0.55: value = sin((phase - 0.35) / 0.20 * .pi) * 0.55
        default: value = 0
        }
        return (value * 4).rounded() / 4
    }

    static func render(appState: AppState, themeManager: ThemeManager, animationDate: Date = Date()) -> NSImage {
        // One cell per provider, not per account. With several logins per
        // provider the bar would otherwise grow without bound, so each cell
        // shows the plan in use — the headroom you are spending now. The panel
        // breaks every plan out individually.
        let services = ServiceType.allCases.compactMap { appState.menuBarRepresentative(for: $0) }
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
        let cellCount = services.count
        let totalWidth = CGFloat(cellCount) * serviceWidth + CGFloat(cellCount - 1) * spacing
        let height: CGFloat = 22

        let snapshot = services.map { service -> ServiceSnapshot in
            return ServiceSnapshot(
                brandColor: service.config.serviceType.brandColor.nsColor,
                serviceType: service.config.serviceType,
                fiveHourUsage: service.fiveHourUsage,
                sevenDayUsage: service.sevenDayUsage,
                usagePercentage: service.usagePercentage,
                isConsuming: service.isConsuming,
                beat: beat(for: service, at: animationDate)
            )
        }

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
            return true
        }

        image.isTemplate = false
        return image
    }

    private struct ServiceSnapshot {
        let brandColor: NSColor
        let serviceType: ServiceType
        let fiveHourUsage: Double?
        let sevenDayUsage: Double?
        let usagePercentage: Double
        let isConsuming: Bool
        let beat: Double
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

        // While an agent is consuming, border and fill pulse with the beat.
        let beat = CGFloat(service.beat)
        let borderPulse: CGFloat = service.isConsuming ? (0.18 + beat * 0.30) : 0
        let activeBorderColor = borderColor.blended(withFraction: borderPulse, of: color) ?? borderColor
        let fillAlpha: CGFloat = service.isConsuming ? (0.86 + beat * 0.14) : 1.0

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

}

extension Color {
    var nsColor: NSColor { NSColor(self) }
}
