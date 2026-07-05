import SwiftUI

struct CircularGaugeView: View {
    let service: ServiceViewModel
    var compact: Bool = false

    @State private var animatedFiveHour: Double = 0
    @State private var animatedSevenDay: Double = 0
    @State private var appeared = false
    @State private var pulseScale: CGFloat = 1.0

    private var outerSize: CGFloat { compact ? 68 : 82 }
    private var innerSize: CGFloat { compact ? 52 : 64 }

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
                } else {
                    VStack(spacing: compact ? -2 : -1) {
                        Text("\(Int(animatedFiveHour * 100))")
                            .font(.system(size: compact ? 20 : 24, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                        Text("\(Int(animatedSevenDay * 100))")
                            .font(.system(size: compact ? 12 : 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }
            }
            .scaleEffect(appeared ? 1.0 : 0.6)
            .opacity(appeared ? 1 : 0)

            Text(service.name)
                .font(.system(size: compact ? 12 : 13, weight: .semibold))
                .foregroundStyle(service.isAuthError ? .secondary : .primary)
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
        if service.isAuthError { return 0 }
        let usage = service.fiveHourUsage ?? service.usagePercentage
        return max(0, (100.0 - usage)) / 100.0
    }

    private var sevenDayRemaining: Double {
        if service.isAuthError { return 0 }
        let usage = service.sevenDayUsage ?? 0
        return max(0, (100.0 - usage)) / 100.0
    }
}
