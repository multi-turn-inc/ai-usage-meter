import SwiftUI

struct PulsingLoadingIndicator: View {
    @State private var phase: CGFloat = 0
    @State private var glowOpacity: Double = 0.4

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(.white.opacity(0.8))
                    .frame(width: 12, height: 12)
                    .blur(radius: 6 + phase * 4)
                    .opacity(glowOpacity)

                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(.white.opacity(0.9))
                    .frame(width: 10, height: 10)
                    .shadow(color: .white.opacity(0.6), radius: 4 + phase * 6)
            }
            .frame(width: 24, height: 24)

            Text(L.updating)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                phase = 1
                glowOpacity = 0.9
            }
        }
    }
}

struct SpinningRefreshButton: View {
    let isRefreshing: Bool
    let action: () -> Void

    @State private var rotation: Double = 0

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(rotation))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(isRefreshing)
        .onChange(of: isRefreshing) { _, refreshing in
            if refreshing {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    rotation = 0
                }
            }
        }
    }
}

extension View {
    /// Apply `.compositingGroup()` only when needed (e.g. blur overlay active).
    /// Avoids the expensive offscreen render pass during normal interaction.
    @ViewBuilder
    func conditionalCompositingGroup(_ active: Bool) -> some View {
        if active {
            self.compositingGroup()
        } else {
            self
        }
    }
}

struct StaggerAppear: ViewModifier {
    let appeared: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
            .animation(
                .spring(response: 0.45, dampingFraction: 0.8).delay(delay),
                value: appeared
            )
    }
}

struct PulseEffect: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.15 : 1.0)
            .opacity(isPulsing ? 0.7 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
    }
}
