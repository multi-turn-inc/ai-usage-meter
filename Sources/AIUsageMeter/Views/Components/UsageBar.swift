import SwiftUI

struct UsageBar: View {
    let label: String
    let percentage: Double
    let resetText: String?
    let color: Color

    @State private var animatedPercentage: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(Int(animatedPercentage))%")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
            }

            GeometryReader { geo in
                let barWidth = geo.size.width * CGFloat(animatedPercentage) / 100
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3.5)
                        .fill(Color(nsColor: .separatorColor).opacity(0.2))
                        .frame(height: 7)

                    RoundedRectangle(cornerRadius: 3.5)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.75), color],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: barWidth, height: 7)
                        .shadow(color: color.opacity(0.25), radius: 3, y: 1)
                }
            }
            .frame(height: 7)

            if let reset = resetText {
                Text(reset)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7).delay(0.1)) {
                animatedPercentage = percentage
            }
        }
        .onChange(of: percentage) { _, newValue in
            withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) {
                animatedPercentage = newValue
            }
        }
    }
}
