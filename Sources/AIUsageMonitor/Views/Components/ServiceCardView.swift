import SwiftUI

struct ServiceCardView: View {
    let service: ServiceViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Service Header
            HStack {
                Image(systemName: service.iconName)
                    .font(.title2)
                    .foregroundStyle(service.brandColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(service.name)
                        .font(.headline)

                    Text(service.tier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                StatusIndicator(status: service.status)
            }

            // Claude-specific Usage Windows
            if service.hasClaudeUsageWindows {
                ClaudeUsageView(
                    fiveHourUsage: service.fiveHourUsage,
                    sevenDayUsage: service.sevenDayUsage
                )
            } else {
                // Standard Usage Bar for other providers
                UsageBarView(
                    current: service.tokensUsed,
                    limit: service.tokensLimit,
                    percentage: service.usagePercentage
                )

                // Usage Details
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Used")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(service.formattedTokensUsed)
                            .font(.caption)
                            .fontWeight(.medium)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Limit")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(service.formattedTokensLimit)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }
            }

            // Cost View
            if let cost = service.currentCost {
                Divider()

                CostView(
                    current: cost,
                    projected: service.projectedCost,
                    currency: service.currency
                )
            }

            // Reset Date
            if let resetDate = service.resetDate {
                Text("Resets \(resetDate, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .premiumCard()
    }
}

struct StatusIndicator: View {
    let status: ServiceStatus

    private var color: Color {
        let theme = ThemeManager.shared.current
        switch status {
        case .normal:
            return theme.statusSuccess
        case .warning:
            return theme.statusWarning
        case .critical:
            return theme.statusDanger
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }
}

struct CostView: View {
    let current: Decimal
    let projected: Decimal?
    let currency: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Current Cost")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(formatCurrency(current))
                    .font(.callout)
                    .fontWeight(.semibold)
            }

            Spacer()

            if let projected = projected {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Projected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(formatCurrency(projected))
                        .font(.callout)
                        .fontWeight(.medium)
                        .foregroundStyle(ThemeManager.shared.current.statusWarning)
                }
            }
        }
    }

    private func formatCurrency(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.maximumFractionDigits = 2
        return formatter.string(from: amount as NSNumber) ?? "$0.00"
    }
}

struct ClaudeUsageView: View {
    let fiveHourUsage: Double?
    let sevenDayUsage: Double?

    var body: some View {
        VStack(spacing: 10) {
            // 5-Hour Usage
            if let fiveHour = fiveHourUsage {
                UsageRow(
                    label: "5-Hour",
                    percentage: fiveHour,
                    color: colorForPercentage(fiveHour)
                )
            }

            // 7-Day Usage
            if let sevenDay = sevenDayUsage {
                UsageRow(
                    label: "7-Day",
                    percentage: sevenDay,
                    color: colorForPercentage(sevenDay)
                )
            }
        }
    }

    private func colorForPercentage(_ percentage: Double) -> Color {
        let theme = ThemeManager.shared.current
        switch percentage {
        case 0..<50: return theme.statusSuccess
        case 50..<75: return theme.statusCaution
        case 75..<90: return theme.statusWarning
        default: return theme.statusDanger
        }
    }
}

struct UsageRow: View {
    let label: String
    let percentage: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f%%", percentage))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(color)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(ThemeManager.shared.current.trackSubtle)
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: geometry.size.width * CGFloat(min(percentage, 100) / 100), height: 6)
                }
            }
            .frame(height: 6)
        }
    }
}
