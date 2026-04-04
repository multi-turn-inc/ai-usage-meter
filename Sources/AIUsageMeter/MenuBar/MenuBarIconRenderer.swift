import AppKit
import SwiftUI

@MainActor
enum MenuBarIconRenderer {

    static func render(appState: AppState, themeManager: ThemeManager, animationDate: Date = Date()) -> NSImage {
        let services = appState.services.filter { $0.config.isEnabled }
        guard !services.isEmpty else {
            return NSImage(size: NSSize(width: 22, height: 22))
        }

        let serviceWidth: CGFloat = 38
        let spacing: CGFloat = 6
        let totalWidth = CGFloat(services.count) * serviceWidth + CGFloat(services.count - 1) * spacing
        let height: CGFloat = 22

        let snapshot = services.map { service -> ServiceSnapshot in
            let remaining = max(
                max(0, 100.0 - (service.fiveHourUsage ?? service.usagePercentage)) / 100.0,
                max(0, 100.0 - (service.sevenDayUsage ?? service.usagePercentage)) / 100.0
            )
            return ServiceSnapshot(
                brandColor: service.config.serviceType.brandColor.nsColor,
                serviceType: service.config.serviceType,
                fiveHourUsage: service.fiveHourUsage,
                sevenDayUsage: service.sevenDayUsage,
                usagePercentage: service.usagePercentage,
                isConsuming: service.isConsuming,
                maxRemaining: remaining
            )
        }

        let elapsed = animationDate.timeIntervalSinceReferenceDate

        let image = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { _ in
            let dark: Bool = {
                switch NSAppearance.current.bestMatch(from: [.darkAqua, .aqua]) {
                case .darkAqua: return true
                default: return false
                }
            }()

            var x: CGFloat = 0
            for service in snapshot {
                drawMeter(at: x, service: service, dark: dark, width: serviceWidth, height: height, elapsed: elapsed)
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
        let maxRemaining: Double
    }

    private static func heartbeatCurve(_ phase: Double) -> Double {
        if phase < 0.12 {
            return sin((phase / 0.12) * .pi)
        } else if phase < 0.20 {
            return 0.04
        } else if phase < 0.32 {
            return sin(((phase - 0.20) / 0.12) * .pi) * 0.55
        } else {
            return 0.03
        }
    }

    private static func drawMeter(
        at x: CGFloat,
        service: ServiceSnapshot,
        dark: Bool,
        width: CGFloat,
        height: CGFloat,
        elapsed: TimeInterval
    ) {
        let color = service.brandColor
        let labelColor = dark ? NSColor.white : NSColor.black
        let borderColor = dark ? NSColor.white.withAlphaComponent(0.55) : NSColor.black.withAlphaComponent(0.40)
        let emptyBarColor = dark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.10)

        let fiveHourRemaining = max(0, 100.0 - (service.fiveHourUsage ?? service.usagePercentage)) / 100.0
        let sevenDayRemaining = max(0, 100.0 - (service.sevenDayUsage ?? service.usagePercentage)) / 100.0

        let timeOffset: TimeInterval = {
            switch service.serviceType {
            case .claude: return 0
            case .codex: return 0.37
            case .gemini: return 0.74
            }
        }()

        let beat: CGFloat = {
            guard service.isConsuming else { return 0 }
            let cycleDuration = 0.8 + (service.maxRemaining * 1.6)
            let phase = (elapsed + timeOffset).truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
            return CGFloat(heartbeatCurve(phase))
        }()

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
        activeBorderColor.setStroke()
        framePath.lineWidth = 0.75
        framePath.stroke()

        let filledBars = max(0, min(barCount, Int((CGFloat(fiveHourRemaining) + 0.05) * CGFloat(barCount))))
        let activityBarIndex: Int? = {
            guard service.isConsuming, filledBars > 0 else { return nil }
            let sweepDuration = 1.6 + service.maxRemaining * 1.2
            let t = (elapsed + timeOffset).truncatingRemainder(dividingBy: sweepDuration) / sweepDuration
            let idx = Int(Double(filledBars) * t)
            return max(0, min(filledBars - 1, idx))
        }()

        for i in 0..<barCount {
            let barX = x + 2 + CGFloat(i) * (barWidth + 1)
            let fillRect = NSRect(x: barX, y: barY, width: barWidth, height: barHeight)

            let barPosition = CGFloat(i + 1) / CGFloat(barCount)
            let shouldFill = barPosition <= CGFloat(fiveHourRemaining) + 0.05

            if shouldFill {
                var fillColor = color.withAlphaComponent(fillAlpha)
                if let activityBarIndex, i == activityBarIndex {
                    fillColor = color.blended(withFraction: 0.26 + beat * 0.30, of: .white) ?? fillColor
                }
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
