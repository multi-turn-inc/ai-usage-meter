import SwiftUI

struct HelpPanel: View {
    @Binding var isPresented: Bool
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        isPresented = false
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)

                Text(L.menuBarLegendTitle)
                    .font(.system(size: 16, weight: .bold))

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            ScrollView {
                VStack(spacing: 16) {
                    Text(L.menuBarLegendDescription)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 8)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.05), value: appeared)

                    MenuBarLegendDiagram(isPresented: appeared)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 12)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1), value: appeared)

                    HStack(spacing: 8) {
                        MenuBarLegendExplainCard(
                            symbol: "arrow.left.and.right",
                            title: "5h",
                            description: L.menuBarLegendHorizontal
                        )
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 10)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: appeared)

                        MenuBarLegendExplainCard(
                            symbol: "arrow.up.and.down",
                            title: "7d",
                            description: L.menuBarLegendVertical
                        )
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 10)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.25), value: appeared)
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
        }
        .onAppear {
            withAnimation { appeared = true }
        }
        .onDisappear { appeared = false }
    }
}

private struct MenuBarLegendExplainCard: View {
    let symbol: String
    let title: String
    let description: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            Text(title)
                .font(.system(size: 14, weight: .bold, design: .rounded))

            Text(description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.2))
                )
        )
    }
}
