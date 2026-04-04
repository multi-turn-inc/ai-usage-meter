import SwiftUI

struct UsageBarView: View {
    let current: Int64
    let limit: Int64
    let percentage: Double

    private var color: Color {
        let theme = ThemeManager.shared.current
        switch percentage {
        case 0..<50: return theme.statusSuccess
        case 50..<75: return theme.statusCaution
        case 75..<90: return theme.statusWarning
        default: return theme.statusDanger
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(Int(percentage))%")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(color)

                Spacer()

                Text("\(formatTokens(current)) / \(formatTokens(limit))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(ThemeManager.shared.current.trackSubtle)
                        .frame(height: 8)

                    // Progress
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.8), color],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(
                            width: max(0, min(geometry.size.width, geometry.size.width * (percentage / 100))),
                            height: 8
                        )
                        .animation(.easeInOut(duration: 0.3), value: percentage)
                }
            }
            .frame(height: 8)
        }
    }

    private func formatTokens(_ tokens: Int64) -> String {
        let value = Double(tokens)
        if value >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000)
        } else if value >= 1_000 {
            return String(format: "%.1fK", value / 1_000)
        } else {
            return "\(Int(value))"
        }
    }
}
