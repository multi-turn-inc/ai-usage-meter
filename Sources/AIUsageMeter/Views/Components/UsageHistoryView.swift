import SwiftUI

struct UsageHistoryView: View {
    let serviceType: ServiceType
    @State private var selectedPeriod: Period = .day

    enum Period: CaseIterable {
        case day
        case week
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text(L.usageHistory)
                    .font(.system(size: 14, weight: .semibold))

                Circle()
                    .fill(serviceColor)
                    .frame(width: 8, height: 8)

                Spacer()

                Picker("", selection: $selectedPeriod) {
                    Text(L.hours24).tag(Period.day)
                    Text(L.days7).tag(Period.week)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }

            // Chart
            if selectedPeriod == .day {
                HourlyChartView(serviceType: serviceType)
            } else {
                DailyChartView(serviceType: serviceType)
            }
        }
        .padding()
        .premiumCard()
    }

    private var serviceColor: Color {
        serviceType.brandColor
    }
}

struct HourlyChartView: View {
    let serviceType: ServiceType
    private let data: [(hour: Int, fiveHour: Double?, sevenDay: Double?)]

    init(serviceType: ServiceType) {
        self.serviceType = serviceType
        self.data = UsageHistoryStore.shared.getHourlyAverages(for: serviceType, hours: 24)
    }

    var body: some View {
        VStack(spacing: 4) {
            // Chart
            GeometryReader { geometry in
                let barWidth = (geometry.size.width - CGFloat(data.count - 1) * 2) / CGFloat(data.count)
                let maxHeight = geometry.size.height - 20

                ZStack(alignment: .bottom) {
                    // Grid lines
                    VStack(spacing: 0) {
                        ForEach([0, 25, 50, 75, 100], id: \.self) { value in
                            if value > 0 {
                                Divider()
                                    .opacity(0.3)
                            }
                            Spacer()
                        }
                    }

                    // Bars
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(Array(data.enumerated()), id: \.offset) { index, entry in
                            VStack(spacing: 1) {
                                // 5-hour bar
                                if let fiveHour = entry.fiveHour {
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(serviceColor.opacity(0.8))
                                        .frame(width: barWidth * 0.45, height: maxHeight * CGFloat(fiveHour) / 100)
                                }
                            }
                            .frame(width: barWidth)
                        }
                    }
                }
            }
            .frame(height: 60)

            // X-axis labels
            HStack {
                Text("0시")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("12시")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("24시")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var serviceColor: Color {
        serviceType.brandColor
    }
}

struct DailyChartView: View {
    let serviceType: ServiceType
    private let data: [(date: Date, fiveHour: Double?, sevenDay: Double?)]

    init(serviceType: ServiceType) {
        self.serviceType = serviceType
        self.data = UsageHistoryStore.shared.getDailyHistory(for: serviceType, days: 7)
    }

    var body: some View {
        VStack(spacing: 4) {
            // Chart
            GeometryReader { geometry in
                let barWidth = (geometry.size.width - CGFloat(data.count - 1) * 4) / CGFloat(data.count)
                let maxHeight = geometry.size.height - 20

                ZStack(alignment: .bottom) {
                    // Grid lines
                    VStack(spacing: 0) {
                        ForEach([0, 25, 50, 75, 100], id: \.self) { value in
                            if value > 0 {
                                Divider()
                                    .opacity(0.3)
                            }
                            Spacer()
                        }
                    }

                    // Bars
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(Array(data.enumerated()), id: \.offset) { index, entry in
                            VStack(spacing: 0) {
                                if let fiveHour = entry.fiveHour {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(serviceColor)
                                        .frame(width: barWidth, height: max(2, maxHeight * CGFloat(fiveHour) / 100))
                                     } else {
                                         RoundedRectangle(cornerRadius: 2)
                                            .fill(ThemeManager.shared.current.trackSubtle)
                                             .frame(width: barWidth, height: 2)
                                     }
                            }
                        }
                    }
                }
            }
            .frame(height: 60)

            // X-axis labels
            HStack {
                ForEach(Array(data.enumerated()), id: \.offset) { index, entry in
                    if index == 0 || index == data.count - 1 || index == data.count / 2 {
                        Text(dayLabel(entry.date))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    if index < data.count - 1 {
                        Spacer()
                    }
                }
            }
        }
    }

    private var serviceColor: Color {
        serviceType.brandColor
    }

    private func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }
}
