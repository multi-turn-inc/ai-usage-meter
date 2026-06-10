import SwiftUI

struct TokenUsageView: View {
    let summary: TokenUsageSummary
    @State private var scopeIndex: Int = 1
    @State private var scrollAccumulator: CGFloat = 0

    private let scopes = TokenTimeScope.allCases
    private var scope: TokenTimeScope { scopes[scopeIndex] }

    var body: some View {
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

                        Text("tokens")
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
        let now = Date()
        let calendar = Calendar.current
        let tf = DateFormatter()
        tf.timeZone = .current

        switch scope {
        case .hour1:
            tf.dateFormat = "HH:mm"
            let start = calendar.date(byAdding: .minute, value: -60, to: now)!
            return (tf.string(from: start), "now")
        case .hours24:
            tf.dateFormat = "HH:mm"
            let start = calendar.date(byAdding: .hour, value: -23, to: now)!
            return (tf.string(from: start), "now")
        case .days7:
            tf.dateFormat = "M/d"
            let start = calendar.date(byAdding: .day, value: -6, to: now)!
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
        case .hour1: return minuteBars(count: 12, minutesPerBar: 5)
        case .hours24: return hourBars(count: 24)
        case .days7: return dayBars(count: 7)
        }
    }

    private func minuteBars(count: Int, minutesPerBar: Int) -> [BarEntry] {
        let now = Date()
        let cutoff = Calendar.current.date(byAdding: .minute, value: -(count * minutesPerBar), to: now)!
        var buckets = Array(repeating: Int64(0), count: count)
        for entry in summary.hourly where entry.timestamp >= cutoff {
            let mins = Int(entry.timestamp.timeIntervalSince(cutoff) / 60)
            let bucket = min(count - 1, mins / minutesPerBar)
            buckets[bucket] += entry.totalTokens
        }
        return buckets.enumerated().map { i, t in BarEntry(tokens: t, isCurrent: i == count - 1) }
    }

    private func hourBars(count: Int) -> [BarEntry] {
        let calendar = Calendar.current
        let now = Date()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH"
        f.timeZone = .current
        let hourlyMap = Dictionary(uniqueKeysWithValues: summary.hourly.map { ($0.hourKey, $0.totalTokens) })
        return (0..<count).map { i in
            let date = calendar.date(byAdding: .hour, value: -(count - 1 - i), to: now)!
            return BarEntry(tokens: hourlyMap[f.string(from: date)] ?? 0, isCurrent: i == count - 1)
        }
    }

    private func dayBars(count: Int) -> [BarEntry] {
        let calendar = Calendar.current
        let now = Date()
        let todayKey = TokenUsageSummary.dayKey(for: now)
        let dailyMap = Dictionary(uniqueKeysWithValues: summary.daily.map { ($0.date, $0.totalTokens) })
        return (0..<count).map { i in
            let date = calendar.date(byAdding: .day, value: -(count - 1 - i), to: now)!
            let key = TokenUsageSummary.dayKey(for: date)
            return BarEntry(tokens: dailyMap[key] ?? 0, isCurrent: key == todayKey)
        }
    }

    private var tokensForScope: Int64 {
        switch scope {
        case .hour1: return summary.tokens(inLastHours: 1)
        case .hours24: return summary.todayTokens
        case .days7: return summary.weekTokens
        }
    }

    private var costForScope: Double {
        switch scope {
        case .hour1: return summary.cost(inLastHours: 1)
        case .hours24: return summary.todayCost
        case .days7: return summary.weekCost
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
