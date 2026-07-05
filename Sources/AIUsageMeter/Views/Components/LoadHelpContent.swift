import SwiftUI

struct LoadHelpContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tint)
                Text(L.loadHelpTitle)
                    .font(.system(size: 13, weight: .semibold))
            }

            row(symbol: "chart.bar.fill", text: L.loadHelpBars)
            row(symbol: "paintpalette.fill", text: L.loadHelpColor)
            row(symbol: "sparkles", text: L.loadHelpDiagnose)
        }
    }

    private func row(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .center)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
