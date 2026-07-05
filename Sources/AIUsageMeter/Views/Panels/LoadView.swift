import AppKit
import SwiftUI

/// The "Load" tab detail: simple CPU / GPU / RAM bars, the top-CPU process list,
/// and an optional on-demand AI diagnosis. The glanceable gauge lives in the menu
/// bar; this is the "open for detail" view.
struct LoadView: View {
    private var load = SystemLoadMonitor.shared
    private var advisor = ThermalAdvisor.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                loadGauge
                cpuProcessList
                memoryProcessList
                Divider().opacity(0.2)
                aiSection
            }
            .padding(12)
        }
        .frame(maxHeight: 560)
        .premiumCard()
        .task {
            // Refresh while the tab is open; auto-cancels when it closes. The menu
            // bar already samples load continuously; here we also refresh the
            // process list (which shells out to `ps`) every ~2s.
            load.sample()
            await advisor.sampleNow()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                load.sample()
                await advisor.sampleNow()
            }
        }
    }

    // MARK: CPU / GPU / RAM bars

    private var loadGauge: some View {
        VStack(spacing: 8) {
            loadBar(label: "CPU", value: load.cpu, color: .blue)
            loadBar(label: "GPU", value: load.gpu, color: .purple)
            loadBar(label: L.ram, value: load.ram, color: SystemLoadMonitor.ramColor(load.ram))
        }
    }

    private func loadBar(label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(nsColor: .separatorColor).opacity(0.18))
                    Capsule().fill(color.gradient)
                        .frame(width: max(4, geo.size.width * CGFloat(min(max(value, 0), 100) / 100)))
                        .animation(.easeOut(duration: 0.6), value: value)
                }
            }
            .frame(height: 8)
            Text("\(Int(value.rounded()))%")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(width: 38, alignment: .trailing)
                .contentTransition(.numericText())
        }
    }

    // MARK: process lists

    /// Clicking any row or the header opens Activity Monitor. Activity Monitor
    /// has no URL scheme, so we can't pre-select a process — but launching the
    /// app is enough to satisfy the "show me more" instinct without any
    /// automation prompts.
    private func openActivityMonitor() {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.ActivityMonitor"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func listHeader(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Image(systemName: "arrow.up.forward")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    @ViewBuilder
    private var cpuProcessList: some View {
        if !advisor.topProcesses.isEmpty {
            Button(action: openActivityMonitor) {
                VStack(spacing: 3) {
                    listHeader(L.topCPU)
                    ForEach(advisor.topProcesses.prefix(3)) { p in
                        HStack {
                            Text(p.name)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text("\(Int(p.cpu.rounded()))%")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(p.cpu >= 50 ? Color.pink : Color.secondary)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L.openActivityMonitor)
        }
    }

    @ViewBuilder
    private var memoryProcessList: some View {
        if !advisor.topMemoryProcesses.isEmpty {
            Button(action: openActivityMonitor) {
                VStack(spacing: 3) {
                    listHeader(L.topMemory)
                    ForEach(advisor.topMemoryProcesses.prefix(3)) { m in
                        HStack {
                            Text(m.name)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text(ThermalAdvisor.formatBytes(m.rssBytes))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L.openActivityMonitor)
        }
    }

    // MARK: AI diagnosis

    @ViewBuilder
    private var aiSection: some View {
        if advisor.hasAPIKey {
            Button {
                advisor.diagnoseNow()
            } label: {
                HStack(spacing: 6) {
                    if advisor.isDiagnosing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "sparkles").font(.system(size: 11))
                    }
                    Text(advisor.isDiagnosing ? L.updating : L.aiDiagnose)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .disabled(advisor.isDiagnosing)

            if let diagnosis = advisor.diagnosis {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                        .foregroundStyle(.pink)
                    Text(diagnosis)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.pink.opacity(0.08))
                )
            }
            if let err = advisor.lastError {
                Text(err).font(.system(size: 10)).foregroundStyle(.red)
            }
        } else {
            Text(L.thermalAdvisorNeedsKey)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}
