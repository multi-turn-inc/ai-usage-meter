import SwiftUI

struct DetailCard: View {
    let service: ServiceViewModel
    var onRefresh: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                Circle()
                    .fill(service.isAuthError ? ThemeManager.shared.current.statusDanger : service.brandColor)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 1) {
                    Text(service.name)
                        .font(.system(size: 14, weight: .semibold))
                    // Only meaningful when a provider has more than one login;
                    // with a single account the provider name already says it.
                    if let accountLabel = service.accountLabel {
                        Text(accountLabel)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()

                if service.isAuthError {
                    Text("재인증 필요")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ThemeManager.shared.current.statusDanger)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .glassEffect(.regular.tint(ThemeManager.shared.current.statusDanger.opacity(0.25)), in: .capsule)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Text(formattedPlan)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(service.brandColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .glassEffect(.regular.tint(service.brandColor.opacity(0.25)), in: .capsule)
                }
            }

            if service.isAuthError {
                AuthErrorView(service: service, onRefresh: onRefresh)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if !service.hasLoaded {
                // Never rendered placeholder zeroes as real numbers: an unloaded
                // row used to read as a full "100% remaining" bar.
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L.updating)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                // Providers report a varying set of windows — Claude added a
                // per-model weekly cap (Fable), Codex dropped its 5-hour one —
                // so render whatever came back rather than a fixed pair.
                let windows = service.usage.windows
                if windows.isEmpty {
                    HStack(spacing: 16) {
                        UsageBar(
                            label: primaryLabel,
                            percentage: max(0, 100 - (service.fiveHourUsage ?? service.usagePercentage)),
                            resetText: primaryResetText,
                            color: service.brandColor
                        )

                        if let sevenDay = service.sevenDayUsage {
                            UsageBar(
                                label: secondaryLabel,
                                percentage: max(0, 100 - sevenDay),
                                resetText: formatReset(service.sevenDayResetDate),
                                color: service.brandColor.opacity(0.5)
                            )
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    HStack(spacing: 14) {
                        ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                            UsageBar(
                                label: window.label,
                                percentage: max(0, 100 - window.percent),
                                resetText: formatReset(window.resetsAt),
                                color: window.isCritical
                                    ? ThemeManager.shared.current.statusDanger
                                    : service.brandColor.opacity(index == 0 ? 1.0 : 0.5)
                            )
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                staleWarningRow
            }
        }
        .padding(12)
        .premiumCard()
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: service.isAuthError)
    }

    /// Nothing while data is fresh. Only when it's stale (>10 min — more than two
    /// missed 5-min cycles) does an orange warning appear, so a frozen value from a
    /// failed refresh isn't mistaken for the current number.
    @ViewBuilder
    private var staleWarningRow: some View {
        let interval = max(0, Date().timeIntervalSince(service.usage.lastUpdated))
        if interval > 600 {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.arrow.circlepath")
                    .font(.system(size: 8, weight: .semibold))
                Text(relativeAge(interval))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help(L.dataStale)
        }
    }

    private func relativeAge(_ interval: TimeInterval) -> String {
        let s = Int(interval)
        if s < 60 { return "<1m" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    private var isGemini: Bool {
        service.config.serviceType == .gemini
    }

    private var primaryLabel: String {
        isGemini ? "Pro" : "5h"
    }

    private var secondaryLabel: String {
        isGemini ? "Flash" : "7d"
    }

    private var formattedPlan: String {
        let tier = service.tier.lowercased()
        if tier.contains("max") {
            return "Max"
        } else if tier.contains("pro") {
            return "Pro"
        } else if tier.contains("team") {
            return "Team"
        } else if tier.contains("enterprise") {
            return "Enterprise"
        } else if tier.contains("free") {
            return "Free"
        }
        return service.tier.components(separatedBy: "_").last?.capitalized ?? service.tier
    }

    private var primaryResetText: String? {
        let usage = service.fiveHourUsage ?? service.usagePercentage
        if usage < 1 && !isGemini {
            return L.resetOnUse
        }
        return formatReset(service.resetDate)
    }

    /// Time until the window resets, as a bare compact duration ("1h 20m", "3d").
    ///
    /// The old "resets in …" sentence didn't survive three windows in a 300pt
    /// panel — every label truncated to "resets in 13…", which reads as broken
    /// and hides the number that matters. A clock glyph carries the meaning and
    /// leaves the whole duration visible.
    private func formatReset(_ date: Date?) -> String? {
        guard let date, case let interval = date.timeIntervalSinceNow, interval > 0 else { return nil }

        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(max(1, minutes))m" }

        let hours = Int(interval / 3600)
        if hours < 24 {
            let remainder = Int((interval.truncatingRemainder(dividingBy: 3600)) / 60)
            return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
        }

        let days = Int(interval / 86400)
        let remainingHours = Int((interval.truncatingRemainder(dividingBy: 86400)) / 3600)
        return remainingHours == 0 ? "\(days)d" : "\(days)d \(remainingHours)h"
    }
}
