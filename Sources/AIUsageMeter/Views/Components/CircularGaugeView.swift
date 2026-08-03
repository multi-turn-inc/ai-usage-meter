import SwiftUI

struct CircularGaugeView: View {
    let service: ServiceViewModel
    var compact: Bool = false
    /// Extra-small variant used once several accounts share the row — five
    /// compact gauges are far wider than the 300pt panel and would be clipped.
    var mini: Bool = false

    @State private var animatedFiveHour: Double = 0
    @State private var animatedSevenDay: Double = 0
    @State private var appeared = false
    @State private var pulseScale: CGFloat = 1.0

    private var outerSize: CGFloat { mini ? 54 : (compact ? 68 : 82) }
    private var innerSize: CGFloat { mini ? 42 : (compact ? 52 : 64) }

    /// With one login per provider the provider name says it all; with several,
    /// the organization is what tells them apart.
    private var gaugeLabel: String {
        guard let account = service.account else { return service.name }
        return AccountRegistry.shared.shortDisplayName(for: account)
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                service.brandColor.opacity(0.08),
                                Color.clear,
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: outerSize / 2
                        )
                    )
                    .frame(width: outerSize + 12, height: outerSize + 12)
                    .scaleEffect(pulseScale)

                Circle()
                    .stroke(Color(nsColor: .separatorColor).opacity(0.25), lineWidth: 5.5)
                    .frame(width: outerSize, height: outerSize)

                Circle()
                    .trim(from: 0, to: CGFloat(animatedFiveHour))
                    .stroke(
                        AngularGradient(
                            colors: [service.brandColor.opacity(0.4), service.brandColor],
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(360 * animatedFiveHour)
                        ),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .frame(width: outerSize, height: outerSize)
                    .rotationEffect(.degrees(-90))
                    .shadow(color: service.brandColor.opacity(0.3), radius: 4)

                Circle()
                    .stroke(Color(nsColor: .separatorColor).opacity(0.18), lineWidth: 4)
                    .frame(width: innerSize, height: innerSize)

                Circle()
                    .trim(from: 0, to: CGFloat(animatedSevenDay))
                    .stroke(
                        service.brandColor.opacity(0.5),
                        style: StrokeStyle(lineWidth: 4.5, lineCap: .round)
                    )
                    .frame(width: innerSize, height: innerSize)
                    .rotationEffect(.degrees(-90))
                    .shadow(color: service.brandColor.opacity(0.2), radius: 3)

                if service.isAuthError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.yellow)
                        .modifier(PulseEffect())
                } else if !service.hasLoaded {
                    // Placeholder data is all zeroes, which would draw a full
                    // ring reading "100" — a login that hasn't answered yet must
                    // not look like a healthy one.
                    Text("—")
                        .font(.system(size: mini ? 16 : (compact ? 20 : 24), weight: .bold, design: .rounded))
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(spacing: compact ? -2 : -1) {
                        Text("\(Int(animatedFiveHour * 100))")
                            .font(.system(size: mini ? 16 : (compact ? 20 : 24), weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                        Text("\(Int(animatedSevenDay * 100))")
                            .font(.system(size: mini ? 9 : (compact ? 12 : 13), weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }
            }
            .scaleEffect(appeared ? 1.0 : 0.6)
            .opacity(appeared ? 1 : 0)

            Text(gaugeLabel)
                .font(.system(size: mini ? 9 : (compact ? 12 : 13), weight: .semibold))
                .foregroundStyle(service.isAuthError ? .secondary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: outerSize + 16)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.65)) {
                appeared = true
            }
            withAnimation(.spring(response: 0.8, dampingFraction: 0.6).delay(0.2)) {
                animatedFiveHour = fiveHourRemaining
                animatedSevenDay = sevenDayRemaining
            }
        }
        .onChange(of: fiveHourRemaining) { _, newValue in
            withAnimation(.spring(response: 0.7, dampingFraction: 0.7)) {
                animatedFiveHour = newValue
            }
            triggerPulse()
        }
        .onChange(of: sevenDayRemaining) { _, newValue in
            withAnimation(.spring(response: 0.7, dampingFraction: 0.7)) {
                animatedSevenDay = newValue
            }
        }
    }

    private func triggerPulse() {
        withAnimation(.easeOut(duration: 0.15)) { pulseScale = 1.08 }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.5).delay(0.15)) { pulseScale = 1.0 }
    }

    private var fiveHourRemaining: Double {
        // An unanswered login draws an empty ring, not a full one.
        if service.isAuthError || !service.hasLoaded { return 0 }
        let usage = service.fiveHourUsage ?? service.usagePercentage
        return max(0, (100.0 - usage)) / 100.0
    }

    private var sevenDayRemaining: Double {
        if service.isAuthError || !service.hasLoaded { return 0 }
        let usage = service.sevenDayUsage ?? 0
        return max(0, (100.0 - usage)) / 100.0
    }
}
