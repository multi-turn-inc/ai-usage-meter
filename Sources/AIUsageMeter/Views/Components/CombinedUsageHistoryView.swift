import SwiftUI

struct CombinedUsageHistoryView: View {
    let serviceTypes: [ServiceType]
    @State private var selectedPeriod: Period = .day

    enum Period: CaseIterable {
        case day
        case week
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L.usageHistory)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()

                HStack(spacing: 0) {
                    ForEach(Period.allCases, id: \.self) { period in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedPeriod = period
                            }
                        } label: {
                            Text(period == .day ? L.hours24 : L.days7)
                                .font(.system(size: 11, weight: selectedPeriod == period ? .semibold : .regular))
                                .foregroundStyle(selectedPeriod == period ? .primary : .tertiary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(selectedPeriod == period ? Color(nsColor: .separatorColor).opacity(0.25) : .clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .separatorColor).opacity(0.1))
                )
            }

            // Chart
            if selectedPeriod == .day {
                CombinedHourlyChartView(serviceTypes: serviceTypes)
            } else {
                CombinedDailyChartView(serviceTypes: serviceTypes)
            }
        }
        .padding()
        .premiumCard()
    }

    private func colorFor(_ type: ServiceType) -> Color {
        type.brandColor
    }
}

struct CombinedHourlyChartView: View {
    let serviceTypes: [ServiceType]

    private var allData: [(serviceType: ServiceType, data: [(hour: Int, fiveHour: Double?, sevenDay: Double?)])] {
        serviceTypes.map { type in
            (type, UsageHistoryStore.shared.getHourlyAverages(for: type, hours: 24))
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let totalBars = 24
                let spacing: CGFloat = 1
                let groupSpacing: CGFloat = 2
                let totalSpacing = groupSpacing * CGFloat(totalBars - 1)
                let barGroupWidth = (geometry.size.width - totalSpacing) / CGFloat(totalBars)
                let serviceCount = CGFloat(max(1, serviceTypes.count))
                let singleBarWidth = max(2, (barGroupWidth - spacing * (serviceCount - 1)) / serviceCount)
                let maxHeight = geometry.size.height

                VStack {
                    Spacer()
                    HStack(alignment: .bottom, spacing: groupSpacing) {
                        ForEach(0..<24, id: \.self) { hour in
                            HStack(alignment: .bottom, spacing: spacing) {
                                ForEach(Array(allData.enumerated()), id: \.offset) { index, serviceData in
                                    let entry = serviceData.data.first { $0.hour == hour }
                                    if let fiveHour = entry?.fiveHour, fiveHour > 0 {
                                        RoundedRectangle(cornerRadius: 1)
                                            .fill(colorFor(serviceData.serviceType))
                                            .frame(width: singleBarWidth, height: max(3, maxHeight * CGFloat(fiveHour) / 100))
                                     } else {
                                         RoundedRectangle(cornerRadius: 1)
                                            .fill(ThemeManager.shared.current.trackSubtle)
                                             .frame(width: singleBarWidth, height: 2)
                                     }
                                }
                            }
                        }
                    }
                }
            }
            .frame(height: 50)

            // X-axis labels
            HStack {
                Text("0")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("12")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("24")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func colorFor(_ type: ServiceType) -> Color {
        type.brandColor
    }
}

struct CombinedDailyChartView: View {
    let serviceTypes: [ServiceType]

    private var allData: [(serviceType: ServiceType, data: [(date: Date, fiveHour: Double?, sevenDay: Double?)])] {
        serviceTypes.map { type in
            (type, UsageHistoryStore.shared.getDailyHistory(for: type, days: 7))
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let totalBars = 7
                let spacing: CGFloat = 2
                let groupSpacing: CGFloat = 6
                let totalSpacing = groupSpacing * CGFloat(totalBars - 1)
                let barGroupWidth = (geometry.size.width - totalSpacing) / CGFloat(totalBars)
                let serviceCount = CGFloat(max(1, serviceTypes.count))
                let singleBarWidth = max(4, (barGroupWidth - spacing * (serviceCount - 1)) / serviceCount)
                let maxHeight = geometry.size.height

                VStack {
                    Spacer()
                    HStack(alignment: .bottom, spacing: groupSpacing) {
                        ForEach(0..<7, id: \.self) { dayIndex in
                            HStack(alignment: .bottom, spacing: spacing) {
                                ForEach(Array(allData.enumerated()), id: \.offset) { index, serviceData in
                                    let entry = dayIndex < serviceData.data.count ? serviceData.data[dayIndex] : nil
                                    if let fiveHour = entry?.fiveHour, fiveHour > 0 {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(colorFor(serviceData.serviceType))
                                            .frame(width: singleBarWidth, height: max(3, maxHeight * CGFloat(fiveHour) / 100))
                                     } else {
                                         RoundedRectangle(cornerRadius: 2)
                                            .fill(ThemeManager.shared.current.trackSubtle)
                                             .frame(width: singleBarWidth, height: 2)
                                     }
                                }
                            }
                        }
                    }
                }
            }
            .frame(height: 50)

            // X-axis labels
            HStack {
                if let firstData = allData.first, !firstData.data.isEmpty {
                    Text(dayLabel(firstData.data.first?.date ?? Date()))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text(dayLabel(firstData.data.last?.date ?? Date()))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func colorFor(_ type: ServiceType) -> Color {
        type.brandColor
    }

    private func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }
}
