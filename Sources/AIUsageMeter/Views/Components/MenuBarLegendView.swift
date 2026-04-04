import SwiftUI

struct MenuBarLegendDiagram: View {
    var fiveHourRemaining: Double = 0.7
    var sevenDayRemaining: Double = 0.45
    var isPresented: Bool = true

    private let barCount = 10

    @State private var activeFilledCount: Int = 0
    @State private var barHeights: [CGFloat] = Array(repeating: 1.0, count: 10)
    @State private var didAppear: Bool = false
    @State private var focus: LegendFocus = .horizontal
    @State private var showFiveHourLabel: Bool = false
    @State private var showSevenDayLabel: Bool = false

    var body: some View {
        let barWidth: CGFloat = 5
        let barSpacing: CGFloat = 2
        let maxBarHeight: CGFloat = 24
        let filledCount = max(0, min(barCount, Int((Double(barCount) * fiveHourRemaining).rounded())))
        let meterWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing + 6
        let accent = Color.accentColor
        let fiveHourPercent = Int(fiveHourRemaining * 100)
        let sevenDayPercent = Int(sevenDayRemaining * 100)

        VStack(spacing: 12) {
            // Realistic menu bar meter mock
            VStack(spacing: 3) {
                Text("Claude")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .opacity(didAppear ? 1 : 0)
                    .animation(.easeOut(duration: 0.2).delay(0.05), value: didAppear)

                ZStack(alignment: .bottomLeading) {
                    // Frame
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                        .frame(width: meterWidth, height: maxBarHeight + 4)
                        .opacity(didAppear ? 1 : 0)
                        .animation(.easeOut(duration: 0.2), value: didAppear)

                    // Bars
                    HStack(alignment: .bottom, spacing: barSpacing) {
                        ForEach(0..<barCount, id: \.self) { idx in
                            let h = maxBarHeight * barHeights[idx]
                            Rectangle()
                                .fill(idx < activeFilledCount ? accent : Color.secondary.opacity(0.15))
                                .frame(width: barWidth, height: h)
                                .opacity(didAppear ? 1 : 0)
                                .animation(
                                    .easeOut(duration: 0.2).delay(0.06 + Double(idx) * 0.015),
                                    value: didAppear
                                )
                        }
                    }
                    .padding(3)
                }
            }
            .padding(.top, 4)

            // Annotation labels
            VStack(spacing: 6) {
                // 5h
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 14)
                    Text("5h")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(focus == .horizontal || focus == .none ? .primary : .secondary)
                    Spacer()
                    if showFiveHourLabel {
                        Text("\(fiveHourPercent)% \(L.menuBarLegendHorizontal)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(focus == .horizontal ? 0.6 : 0.3))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(focus == .horizontal ? accent.opacity(0.4) : Color.clear, lineWidth: 1)
                        )
                )
                .scaleEffect(focus == .horizontal ? 1.02 : 1.0)
                .opacity(didAppear ? 1 : 0)
                .offset(y: didAppear ? 0 : 6)
                .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.12), value: didAppear)

                // 7d
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.and.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 14)
                    Text("7d")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(focus == .vertical || focus == .none ? .primary : .secondary)
                    Spacer()
                    if showSevenDayLabel {
                        Text("\(sevenDayPercent)% \(L.menuBarLegendVertical)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(focus == .vertical ? 0.6 : 0.3))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(focus == .vertical ? accent.opacity(0.4) : Color.clear, lineWidth: 1)
                        )
                )
                .scaleEffect(focus == .vertical ? 1.02 : 1.0)
                .opacity(didAppear ? 1 : 0)
                .offset(y: didAppear ? 0 : 6)
                .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.16), value: didAppear)
            }
            .animation(.easeInOut(duration: 0.25), value: focus)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.28), lineWidth: 1)
                )
        )
        .frame(width: 220)
        .task(id: "\(fiveHourRemaining)-\(sevenDayRemaining)-\(isPresented)") {
            guard isPresented else { return }
            let targetHeight = max(0.2, min(1.0, CGFloat(sevenDayRemaining)))
            let filledTarget = filledCount

            await MainActor.run {
                didAppear = false
                activeFilledCount = barCount  // start fully filled
                barHeights = Array(repeating: 1.0, count: barCount) // start at full height
                focus = .horizontal
                showFiveHourLabel = false
                showSevenDayLabel = false
            }

            // Phase 1: Meter appears (fully filled, full height)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) {
                    didAppear = true
                }
            }

            try? await Task.sleep(nanoseconds: 500_000_000)

            // Phase 2: 5h — unfill bars from right to left, then show label
            if Task.isCancelled { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.3)) {
                    focus = .horizontal
                }
            }

            try? await Task.sleep(nanoseconds: 200_000_000)

            for i in stride(from: barCount, through: filledTarget, by: -1) {
                if Task.isCancelled { return }
                await MainActor.run {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) {
                        activeFilledCount = i
                    }
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }

            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    showFiveHourLabel = true
                }
            }

            // Phase 3: 7d — shrink height from full to target, then show label
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.3)) {
                    focus = .vertical
                }
            }

            try? await Task.sleep(nanoseconds: 200_000_000)

            for i in 0..<barCount {
                if Task.isCancelled { return }
                await MainActor.run {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) {
                        barHeights[i] = targetHeight
                    }
                }
                try? await Task.sleep(nanoseconds: 45_000_000)
            }

            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    showSevenDayLabel = true
                }
            }

            // Phase 4: Both visible
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.3)) {
                    focus = .none
                }
            }
        }
    }
}

private enum LegendFocus: Int {
    case horizontal
    case vertical
    case none
}

struct MenuBarLegendCard: View {
    let showsDismissButton: Bool
    var onDismiss: (() -> Void)?
    var isPresented: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MenuBarLegendContent(isPresented: isPresented, showsDescription: false, showsBadges: false)
            if showsDismissButton {
                Button(action: { onDismiss?() }) {
                    Text(L.menuBarLegendGotIt)
                        .font(.system(size: 12.5, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MenuBarLegendPrimaryButtonStyle())
                .modifier(MenuBarLegendAppear(isPresented: isPresented, delay: 0.28))
            }
        }
        .padding(12)
        .onboardingCard(cornerRadius: 18)
    }
}

struct MenuBarLegendContent: View {
    var isPresented: Bool = true
    var showsDescription: Bool = false
    var showsBadges: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L.menuBarLegendTitle)
                    .font(.system(size: 13, weight: .bold))
                    .modifier(MenuBarLegendAppear(isPresented: isPresented, delay: 0.0))

                if showsDescription {
                    Text(L.menuBarLegendDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .modifier(MenuBarLegendAppear(isPresented: isPresented, delay: 0.04))
                } else {
                    Text(L.menuBarLegendQuickTip)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .modifier(MenuBarLegendAppear(isPresented: isPresented, delay: 0.04))
                }
            }

            VStack(spacing: 8) {
                MenuBarLegendDiagram(isPresented: isPresented)
                    .modifier(MenuBarLegendAppear(isPresented: isPresented, delay: 0.10))

                if showsBadges {
                    HStack(spacing: 8) {
                        MenuBarLegendPill(symbol: "arrow.right", text: L.menuBarLegendHorizontal)
                            .modifier(MenuBarLegendAppear(isPresented: isPresented, delay: 0.16))
                        MenuBarLegendPill(symbol: "arrow.up", text: L.menuBarLegendVertical)
                            .modifier(MenuBarLegendAppear(isPresented: isPresented, delay: 0.20))
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct MenuBarLegendPill: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 11.5, weight: .semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onboardingPill(cornerRadius: 10)
    }
}

struct MenuBarLegendOnboardingOverlay: View {
    let onDismiss: () -> Void

    @State private var appeared: Bool = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.58),
                            Color.black.opacity(0.34),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .ignoresSafeArea()
                .onTapGesture { }
                .opacity(appeared ? 1.0 : 0.0)
                .animation(.easeOut(duration: 0.22), value: appeared)

            MenuBarLegendCard(showsDismissButton: true, onDismiss: onDismiss, isPresented: appeared)
                .frame(width: 276)
                .padding(16)
                .offset(y: appeared ? 0 : 14)
                .scaleEffect(appeared ? 1.0 : 0.94)
                .opacity(appeared ? 1.0 : 0.0)
                .onAppear {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                        appeared = true
                    }
                }
        }
        .accessibilityAddTraits(.isModal)
    }
}

private struct MenuBarLegendAppear: ViewModifier {
    let isPresented: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(isPresented ? 1.0 : 0.0)
            .offset(y: isPresented ? 0 : 8)
            .animation(
                .spring(response: 0.48, dampingFraction: 0.86)
                    .delay(delay),
                value: isPresented
            )
    }
}

private struct MenuBarLegendCardStyle: ViewModifier {
    let cornerRadius: CGFloat

    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        let baseFill = Color(nsColor: .windowBackgroundColor)
            .opacity(scheme == .dark ? 0.94 : 0.98)

        let border = Color(nsColor: .separatorColor)
            .opacity(scheme == .dark ? 0.55 : 0.35)

        let highlight = LinearGradient(
            colors: [
                Color.white.opacity(scheme == .dark ? 0.14 : 0.22),
                Color.white.opacity(0.0),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        return content
            .background(shape.fill(baseFill))
            .overlay(shape.stroke(border, lineWidth: 1).allowsHitTesting(false))
            .overlay(shape.fill(highlight).blendMode(.overlay).allowsHitTesting(false))
            .clipShape(shape)
            .shadow(
                color: Color.black.opacity(scheme == .dark ? 0.35 : 0.14),
                radius: 22,
                y: 10
            )
    }
}

private struct MenuBarLegendPillStyle: ViewModifier {
    let cornerRadius: CGFloat

    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        let fill = Color(nsColor: .controlBackgroundColor)
            .opacity(scheme == .dark ? 0.70 : 0.85)

        let border = Color(nsColor: .separatorColor)
            .opacity(scheme == .dark ? 0.35 : 0.22)

        return content
            .background(shape.fill(fill))
            .overlay(shape.stroke(border, lineWidth: 0.8).allowsHitTesting(false))
            .clipShape(shape)
    }
}

private extension View {
    func onboardingCard(cornerRadius: CGFloat = 18) -> some View {
        modifier(MenuBarLegendCardStyle(cornerRadius: cornerRadius))
    }

    func onboardingPill(cornerRadius: CGFloat = 10) -> some View {
        modifier(MenuBarLegendPillStyle(cornerRadius: cornerRadius))
    }
}

private struct MenuBarLegendPrimaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let base = Color.accentColor

        let highlight = LinearGradient(
            colors: [
                Color.white.opacity(0.28),
                Color.white.opacity(0.0),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        return configuration.label
            .foregroundStyle(Color.white)
            .background(
                shape
                    .fill(base)
                    .overlay(shape.fill(highlight).blendMode(.overlay).allowsHitTesting(false))
                    .overlay(
                        shape.stroke(
                            Color.white.opacity(scheme == .dark ? 0.18 : 0.12),
                            lineWidth: 0.8
                        )
                        .blendMode(.overlay)
                        .allowsHitTesting(false)
                    )
            )
            .shadow(
                color: Color.black.opacity(scheme == .dark ? 0.30 : 0.18),
                radius: configuration.isPressed ? 10 : 16,
                y: configuration.isPressed ? 4 : 8
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
