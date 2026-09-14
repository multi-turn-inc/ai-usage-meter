import SwiftUI
import AIUsageMeterCore

struct TokenUsageView: View {
    let summary: TokenUsageSummary
    @State private var scopeIndex: Int = 1
    @State private var scrollAccumulator: CGFloat = 0

    private let scopes = TokenTimeScope.allCases
    private var scope: TokenTimeScope { scopes[scopeIndex] }

    var body: some View {
        let now = summary.lastParsed
        VStack(spacing: 8) {
            // Number + scope picker
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(formatTokens(tokensForScope))
                            .font(.system(size: 24, weight: .heavy, design: .rounded))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .contentTransition(.numericText())

                        Text("tokens (incl. cache)")
                            .font(.system(size: 11))
                            .foregroundStyle(.quaternary)
                    }

                    if costForScope > 0 {
                        Text("≈ \(formatCost(costForScope)) API")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .contentTransition(.numericText())
                            .help("Estimated cost at pay-per-use API prices")
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: scopeIndex)

                Spacer()

                scopePicker
            }

            // Chart
            unifiedChartView
                .frame(height: 48)
        }
        .padding(12)
        .premiumCard()
        .contentShape(Rectangle())
        .onScrollWheel { delta in handleScroll(delta: delta) }
        .gesture(
            DragGesture(minimumDistance: 15)
                .onEnded { v in
                    if v.translation.width < -25 { advanceScope(1) }
                    else if v.translation.width > 25 { advanceScope(-1) }
                }
        )
    }

    // MARK: - Scope Picker

    private var scopePicker: some View {
        HStack(spacing: 0) {
            ForEach(Array(scopes.enumerated()), id: \.offset) { i, s in
                Text(s.rawValue)
                    .font(.system(size: i == scopeIndex ? 13 : 10,
                                  weight: i == scopeIndex ? .bold : .regular,
                                  design: .monospaced))
                    .foregroundStyle(i == scopeIndex ? .primary : .quaternary)
                    .frame(width: i == scopeIndex ? 32 : 22, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(i == scopeIndex ? Color(nsColor: .separatorColor).opacity(0.18) : .clear)
                    )
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { scopeIndex = i }
                    }
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .separatorColor).opacity(0.06))
        )
    }

    // MARK: - Unified Chart

    private var unifiedChartView: some View {
        let labels = timeLabels
        return VStack(spacing: 3) {
            GeometryReader { geo in
                let bars = barsForCurrentScope
                let maxVal = max(bars.map(\.tokens).max() ?? 1, 1)
                let count = CGFloat(max(bars.count, 1))
                let gap: CGFloat = bars.count > 50 ? 0.5 : bars.count > 14 ? 1.5 : 3
                let barW = (geo.size.width - gap * (count - 1)) / count

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(alignment: .bottom, spacing: gap) {
                        ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                            let ratio = CGFloat(bar.tokens) / CGFloat(maxVal)
                            let barH = bar.tokens > 0 ? max(ratio * geo.size.height, 3) : 0

                            RoundedRectangle(cornerRadius: barW > 5 ? 3 : 1.5, style: .continuous)
                                .fill(barColor(bar: bar, ratio: ratio))
                                .frame(width: barW, height: max(barH, 1.5))
                        }
                    }
                }
            }

            HStack {
                Text(labels.start)
                Spacer()
                Text(labels.end)
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
    }

    private var timeLabels: (start: String, end: String) {
        let now = summary.lastParsed
        let calendar = Calendar.current
        let tf = DateFormatter()
        tf.timeZone = .current

        switch scope {
        case .hour1:
            tf.dateFormat = "HH:mm"
            let start = calendar.date(byAdding: .minute, value: -60, to: now)!
            return (tf.string(from: start), tf.string(from: now))
        case .hours24:
            tf.dateFormat = "HH:mm"
            let start = calendar.date(byAdding: .hour, value: -24, to: now)!
            return (tf.string(from: start), tf.string(from: now))
        case .days7:
            tf.dateFormat = "M/d"
            let start = now.addingTimeInterval(-Double(24 * 7) * 3600)
            return (tf.string(from: start), tf.string(from: now))
        }
    }

    private func barColor(bar: BarEntry, ratio: CGFloat) -> Color {
        if bar.tokens == 0 { return Color(nsColor: .separatorColor).opacity(0.1) }
        if bar.isCurrent { return Color.orange.opacity(0.5 + ratio * 0.4) }
        return Color.blue.opacity(0.15 + ratio * 0.4)
    }

    // MARK: - Scroll

    private func handleScroll(delta: CGFloat) {
        scrollAccumulator += delta
        if scrollAccumulator > 2.5 {
            scrollAccumulator = 0
            advanceScope(1)
        } else if scrollAccumulator < -2.5 {
            scrollAccumulator = 0
            advanceScope(-1)
        }
    }

    private func advanceScope(_ direction: Int) {
        let next = scopeIndex + direction
        guard next >= 0, next < scopes.count else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { scopeIndex = next }
    }

    // MARK: - Data

    private struct BarEntry {
        let tokens: Int64
        let isCurrent: Bool
    }

    private var barsForCurrentScope: [BarEntry] {
        switch scope {
        case .hour1: return bucketBars(hours: 1, count: 12)
        case .hours24: return bucketBars(hours: 24, count: 24)
        case .days7: return bucketBars(hours: 24 * 7, count: 7)
        }
    }

    private func bucketBars(hours: Int, count: Int) -> [BarEntry] {
        summary.buckets(inLastHours: hours, count: count, now: summary.lastParsed)
            .enumerated().map { BarEntry(tokens: $0.element, isCurrent: $0.offset == count - 1) }
    }

    private var tokensForScope: Int64 {
        switch scope {
        case .hour1: return summary.tokens(inLastHours: 1, now: summary.lastParsed)
        case .hours24: return summary.tokens(inLastHours: 24, now: summary.lastParsed)
        case .days7: return summary.tokens(inLastHours: 24 * 7, now: summary.lastParsed)
        }
    }

    private var costForScope: Double {
        switch scope {
        case .hour1: return summary.cost(inLastHours: 1, now: summary.lastParsed)
        case .hours24: return summary.cost(inLastHours: 24, now: summary.lastParsed)
        case .days7: return summary.cost(inLastHours: 24 * 7, now: summary.lastParsed)
        }
    }

    private func formatCost(_ cost: Double) -> String {
        if cost < 0.01 { return "<$0.01" }
        if cost >= 100 { return String(format: "$%.0f", cost) }
        return String(format: "$%.2f", cost)
    }
}

// MARK: - Scroll Wheel

private struct ScrollWheelModifier: ViewModifier {
    let handler: (CGFloat) -> Void
    func body(content: Content) -> some View {
        content.overlay(ScrollWheelView(handler: handler))
    }
}

private struct ScrollWheelView: NSViewRepresentable {
    let handler: (CGFloat) -> Void
    func makeNSView(context: Context) -> ScrollWheelNSView {
        let v = ScrollWheelNSView()
        v.handler = handler
        return v
    }
    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.handler = handler
    }
}

private class ScrollWheelNSView: NSView {
    var handler: ((CGFloat) -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil // Pass all clicks through to SwiftUI
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.window != nil else { return event }
                let pt = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(pt) {
                    let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                        ? event.scrollingDeltaX : -event.scrollingDeltaY
                    self.handler?(delta)
                }
                return event
            }
        }
    }

    override func removeFromSuperview() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        super.removeFromSuperview()
    }
}

extension View {
    func onScrollWheel(_ handler: @escaping (CGFloat) -> Void) -> some View {
        modifier(ScrollWheelModifier(handler: handler))
    }
}

// MARK: - Formatting

func formatTokens(_ count: Int64) -> String {
    if count >= 1_000_000_000 {
        return String(format: "%.1fB", Double(count) / 1_000_000_000)
    } else if count >= 1_000_000 {
        return String(format: "%.1fM", Double(count) / 1_000_000)
    } else if count >= 1_000 {
        return String(format: "%.1fK", Double(count) / 1_000)
    }
    return "\(count)"
}
