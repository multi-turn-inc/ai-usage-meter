import Foundation
import AppKit

/// Watches the system thermal state and, when the Mac gets hot, asks an LLM
/// (the user's own Anthropic API key) what's likely causing it and what to do.
///
/// Opt-in only: nothing is collected or sent unless the user enables it AND has
/// entered an API key. Even then it runs solely when the thermal state reaches
/// `.serious`/`.critical`, with a cooldown, so it isn't a constant background cost.
/// The only data leaving the machine is the short list of top-CPU process *names*
/// + the thermal level — never tokens, credentials, or file contents.
@MainActor
@Observable
final class ThermalAdvisor {
    static let shared = ThermalAdvisor()

    // MARK: Observable state
    var thermalState: ProcessInfo.ThermalState = .nominal
    var diagnosis: String?          // LLM cause + recommendation
    var topProcesses: [ProcSample] = []
    var isDiagnosing = false
    var lastDiagnosedAt: Date?
    var lastError: String?

    struct ProcSample: Identifiable {
        let id = UUID()
        let name: String
        let cpu: Double
    }

    // MARK: Settings (persisted)
    var isEnabled: Bool {
        get { AppDefaults.userDefaults.bool(forKey: Self.enabledKey) }
        set {
            AppDefaults.userDefaults.set(newValue, forKey: Self.enabledKey)
            if newValue { evaluate() }
        }
    }

    /// Observable mirror of "is a key present" so the UI updates after Save.
    var hasAPIKey = false

    private static let enabledKey = "thermalAdvisorEnabled"
    private let cooldown: TimeInterval = 30 * 60
    private let model = "claude-haiku-4-5"

    private var keyFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TokenBurn/anthropic_api_key", isDirectory: false)
    }

    @ObservationIgnored private var cachedKey: String?
    @ObservationIgnored private var keyLoaded = false

    private init() {
        thermalState = ProcessInfo.processInfo.thermalState
        hasAPIKey = (apiKey != nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(thermalStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification, object: nil
        )
    }

    // MARK: - API key (0600 file, not Keychain — avoids ad-hoc-signing prompts)

    /// Cached in memory so it isn't re-read from disk on every SwiftUI body pass.
    var apiKey: String? {
        if !keyLoaded {
            cachedKey = (try? String(contentsOf: keyFileURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            keyLoaded = true
        }
        return (cachedKey?.isEmpty == false) ? cachedKey : nil
    }

    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let fm = FileManager.default
        let dir = keyFileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if trimmed.isEmpty {
            try? fm.removeItem(at: keyFileURL)
        } else {
            try? trimmed.write(to: keyFileURL, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFileURL.path)
        }
        cachedKey = trimmed
        keyLoaded = true
        hasAPIKey = !trimmed.isEmpty
    }

    // MARK: - Thermal handling

    @objc private func thermalStateChanged() {
        let state = ProcessInfo.processInfo.thermalState
        Task { @MainActor in
            self.thermalState = state
            self.evaluate()
        }
    }

    /// Auto-diagnose when hot, if enabled + keyed + past the cooldown.
    private func evaluate() {
        guard isEnabled, hasAPIKey, !isDiagnosing else { return }
        guard thermalState == .serious || thermalState == .critical else { return }
        if let last = lastDiagnosedAt, Date().timeIntervalSince(last) < cooldown { return }
        Task { await diagnose() }
    }

    /// Called at app launch so the advisor is resident and checks an
    /// already-hot launch state (the notification only fires on changes).
    func start() {
        thermalState = ProcessInfo.processInfo.thermalState
        evaluate()
    }

    /// Lightweight local refresh for the always-on summary strip: updates the
    /// thermal state and top-CPU list with NO network/LLM call. Safe to call
    /// while the panel is open.
    func sampleNow() async {
        thermalState = ProcessInfo.processInfo.thermalState
        topProcesses = await Self.topCPUProcesses()
    }

    /// Manual "diagnose now" — explicit user action counts as consent, so it only
    /// needs an API key (not the auto-when-hot opt-in). Ignores cooldown.
    func diagnoseNow() {
        guard hasAPIKey, !isDiagnosing else { return }
        Task { await diagnose() }
    }

    func diagnose() async {
        // Authoritative guard, on the MainActor before any suspension point — the
        // checks in evaluate()/diagnoseNow() only gate scheduling, so two tasks can
        // reach here; this prevents a second concurrent (paid) request.
        guard !isDiagnosing else { return }
        guard let key = apiKey, !key.isEmpty else { return }
        isDiagnosing = true
        lastError = nil
        defer { isDiagnosing = false }

        let samples = await Self.topCPUProcesses()
        topProcesses = samples
        let stateLabel = Self.label(for: thermalState)

        do {
            let text = try await requestDiagnosis(apiKey: key, processes: samples, thermalLabel: stateLabel)
            diagnosis = text
            lastDiagnosedAt = Date()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Telemetry (local, no root)

    /// Top processes by %CPU via `ps`. Names only — no arguments/paths.
    static func topCPUProcesses(limit: Int = 6) async -> [ProcSample] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/ps")
                task.arguments = ["-Aceo", "pid,pcpu,comm", "-r"]
                // Force C locale so %CPU is always '.'-formatted (Swift's Double()
                // rejects comma decimals, which would drop every row otherwise).
                task.environment = ["LC_ALL": "C"]
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = FileHandle.nullDevice
                guard (try? task.run()) != nil else {
                    continuation.resume(returning: [])
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                let output = String(data: data, encoding: .utf8) ?? ""

                var samples: [ProcSample] = []
                for line in output.split(separator: "\n").dropFirst() {  // skip header
                    let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                    guard parts.count >= 3, let cpu = Double(parts[1]) else { continue }
                    let name = parts[2...].joined(separator: " ")
                    samples.append(ProcSample(name: String(name), cpu: cpu))
                    if samples.count >= limit { break }
                }
                continuation.resume(returning: samples)
            }
        }
    }

    static func label(for state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    // MARK: - LLM

    private func requestDiagnosis(apiKey: String, processes: [ProcSample], thermalLabel: String) async throws -> String {
        let procList = processes.map { "\($0.name): \(String(format: "%.0f", $0.cpu))% CPU" }.joined(separator: "\n")
        let language = LocalizationManager.shared.currentLanguage.displayName

        let hot = thermalState == .serious || thermalState == .critical
        let situation = hot
            ? "The Mac is running hot (thermal pressure: \(thermalLabel))."
            : "The Mac's temperature is currently \(thermalLabel) (not overheating). The user is checking proactively."
        let guidance = hot
            ? "Name the most likely culprit and give ONE concrete, safe action — prefer quitting the specific app over `killall` or rebooting."
            : "If nothing looks problematic, say so reassuringly in one sentence. Only flag a process if it's a sustained user app worth watching."

        let prompt = """
        You are a macOS performance assistant. \(situation)
        Top processes by CPU right now (a process briefly near 100% is normal):
        \(procList)

        Note: several macOS system processes spike briefly during indexing, ML-model \
        compilation, photo analysis, or backup and then settle on their own — e.g. \
        ANECompilerService, mediaanalysisd, photoanalysisd, mds / mds_stores / mdworker, \
        spotlightknowledged, backupd, kernel_task, and *syncd helpers. For those, advise \
        waiting a minute rather than force-quitting or rebooting.

        Respond in \(language), 2-3 short sentences, no preamble. \(guidance)
        """

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 400,
            "messages": [["role": "user", "content": prompt]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AdvisorError.message("No response")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 { throw AdvisorError.message(L.invalidAPIKey) }
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0?["error"] as? [String: Any])?["message"] as? String }
            throw AdvisorError.message(detail ?? "HTTP \(http.statusCode)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            throw AdvisorError.message("Unexpected response")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum AdvisorError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let m): return m }
        }
    }
}
