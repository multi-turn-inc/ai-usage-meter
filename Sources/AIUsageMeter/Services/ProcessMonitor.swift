import Foundation
import AIUsageMeterCore

/// Detects when a user's Claude/Codex/Gemini CLI is actively hitting the AI
/// backends by watching per-process network counters and TCP:443 endpoints.
///
/// Thread model
/// ------------
/// All mutable state (activeServices, resolvedIPs, counters, etc.) lives on
/// the main actor. The heavy subprocess work — `nettop`, `lsof`, `ps`, and
/// DNS resolution — runs in `Task.detached` so the main thread never blocks.
/// Detached helpers return values; the main-actor code applies them.
@MainActor
final class ProcessMonitor {
    static let shared = ProcessMonitor()

    private(set) var activeServices: Set<ServiceType> = []

    private var timer: Timer?
    private var pollTask: Task<Void, Never>?
    private let pollInterval: TimeInterval = 5

    // nonisolated so pure helpers can reach these without needing the actor.
    nonisolated static let apiEndpoints: [(host: String, service: ServiceType)] = [
        ("api.anthropic.com", .claude),
        ("api.openai.com", .codex),
        ("chatgpt.com", .codex),
        ("generativelanguage.googleapis.com", .gemini),
    ]

    private var resolvedIPs: [String: ServiceType] = [:]
    private var pollCount = 0
    private var lastProcessCounters: [Int32: (inBytes: Int64, outBytes: Int64)] = [:]
    private var lastActiveAt: [ServiceType: Date] = [:]

    private nonisolated static let minimumProcessDeltaBytes: Int64 = 4096
    private nonisolated static let activityGraceInterval: TimeInterval = 4

    private init() {}

    func start() {
        stop()
        lastProcessCounters.removeAll()
        lastActiveAt.removeAll()

        Task { [weak self] in
            let ips = await Self.resolveAllHosts()
            self?.resolvedIPs = ips
        }

        schedulePoll()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.schedulePoll()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pollTask?.cancel()
        pollTask = nil
        activeServices = []
        lastProcessCounters.removeAll()
        lastActiveAt.removeAll()
    }

    func isActive(_ serviceType: ServiceType) -> Bool {
        activeServices.contains(serviceType)
    }

    /// Kicks off one poll iteration: subprocesses run on a detached task,
    /// results are applied back on the main actor. Coalesces overlapping runs
    /// so a slow `nettop` can't stack up with the 5-s timer.
    private func schedulePoll() {
        if let existing = pollTask, !existing.isCancelled { return }

        // Snapshot the state the detached task needs. Value copies are safe to
        // hand across actor boundaries.
        let previousCounters = lastProcessCounters
        let currentResolvedIPs = resolvedIPs

        pollTask = Task.detached(priority: .utility) { [weak self] in
            let (deltas, newCounters) = Self.sampleProcessDeltas(previous: previousCounters)
            let detected = Self.getActiveServicesFromConnections(
                processDeltas: deltas,
                resolvedIPs: currentResolvedIPs
            )

            await MainActor.run { [weak self] in
                self?.applyPollResults(detected: detected, newCounters: newCounters)
            }
        }
    }

    /// Applies the results of one detached poll on the main actor.
    private func applyPollResults(
        detected: Set<ServiceType>,
        newCounters: [Int32: (inBytes: Int64, outBytes: Int64)]
    ) {
        lastProcessCounters = newCounters

        var newActive = detected
        let now = Date()
        for service in newActive {
            lastActiveAt[service] = now
        }
        for service in ServiceType.allCases where !newActive.contains(service) {
            if let lastSeen = lastActiveAt[service],
               now.timeIntervalSince(lastSeen) < Self.activityGraceInterval {
                newActive.insert(service)
            }
        }
        if newActive != activeServices {
            activeServices = newActive
        }

        pollTask = nil
        pollCount += 1
        if pollCount % 60 == 0 {
            Task { [weak self] in
                let ips = await Self.resolveAllHosts()
                self?.resolvedIPs = ips
            }
        }
    }

    // MARK: - Pure helpers (nonisolated so they can run off the main actor)

    private nonisolated static func resolveAllHosts() async -> [String: ServiceType] {
        await Task.detached(priority: .utility) {
            var newIPs: [String: ServiceType] = [:]
            for (host, service) in apiEndpoints {
                for ip in resolveHost(host) {
                    newIPs[ip] = service
                }
            }
            return newIPs
        }.value
    }

    private nonisolated static func resolveHost(_ hostname: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(hostname, nil, &hints, &result) == 0, let addrList = result else { return [] }
        defer { freeaddrinfo(addrList) }

        var ips: Set<String> = []
        var current: UnsafeMutablePointer<addrinfo>? = addrList

        while let addr = current {
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                addr.pointee.ai_addr, addr.pointee.ai_addrlen,
                &hostBuffer, socklen_t(hostBuffer.count),
                nil, 0, NI_NUMERICHOST
            ) == 0 {
                ips.insert(String(cString: hostBuffer))
            }
            current = addr.pointee.ai_next
        }

        return Array(ips)
    }

    private nonisolated static func shouldCountConnection(command: String, pid: Int32, service: ServiceType) -> Bool {
        switch service {
        case .claude:
            let c = command.lowercased()
            if c.contains("claude") { return true }

            if c == "node" || c == "python" || c == "python3" || c == "deno" {
                guard let cmdline = commandLine(for: pid)?.lowercased() else { return false }
                if cmdline.contains("claude") || cmdline.contains("anthropic") { return true }
            }

            return false
        case .codex:
            let c = command.lowercased()
            if c.contains("codex") || c.contains("opencode") { return true }

            if c == "node" || c == "python" || c == "python3" || c == "deno" {
                guard let cmdline = commandLine(for: pid)?.lowercased() else { return false }
                if cmdline.contains("codex") || cmdline.contains("opencode") {
                    return true
                }
            }

            return false
        case .gemini:
            let c = command.lowercased()
            if c.contains("gemini") { return true }

            if c == "node" || c == "python" || c == "python3" || c == "deno" {
                guard let cmdline = commandLine(for: pid)?.lowercased() else { return false }
                if cmdline.contains("gemini") { return true }
            }

            return false
        }
    }

    private nonisolated static func hintedService(command: String, pid: Int32) -> ServiceType? {
        let c = command.lowercased()

        if c.contains("gemini") { return .gemini }
        if c.contains("claude") { return .claude }
        if c.contains("codex") || c.contains("opencode") { return .codex }

        if c == "node" || c == "python" || c == "python3" || c == "deno" {
            guard let cmdline = commandLine(for: pid)?.lowercased() else { return nil }

            if cmdline.contains("gemini") { return .gemini }
            if cmdline.contains("claude") || cmdline.contains("anthropic") { return .claude }
            if cmdline.contains("codex") || cmdline.contains("opencode") {
                return .codex
            }
        }

        return nil
    }

    private nonisolated static func runWithTimeout(_ process: Process, pipe: Pipe, timeout: TimeInterval = 5) -> Data? {
        do { try process.run() } catch { return nil }
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    private nonisolated static func commandLine(for pid: Int32) -> String? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "command="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .utility

        guard let data = runWithTimeout(process, pipe: pipe, timeout: 3) else { return nil }

        guard let output = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Returns (deltas, newCounters). Pure: no shared state read/written.
    private nonisolated static func sampleProcessDeltas(
        previous: [Int32: (inBytes: Int64, outBytes: Int64)]
    ) -> (deltas: [Int32: Int64], current: [Int32: (inBytes: Int64, outBytes: Int64)]) {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .utility

        guard let data = runWithTimeout(process, pipe: pipe, timeout: 5) else { return ([:], previous) }

        guard let output = String(data: data, encoding: .utf8) else { return ([:], previous) }

        var current: [Int32: (inBytes: Int64, outBytes: Int64)] = [:]
        var deltas: [Int32: Int64] = [:]

        for line in output.split(separator: "\n") {
            let parts = String(line).split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }

            let procWithPid = String(parts[0])
            guard let dotIndex = procWithPid.lastIndex(of: ".") else { continue }
            let pidText = procWithPid[procWithPid.index(after: dotIndex)...]
            guard let pid = Int32(pidText) else { continue }

            guard let inBytes = Int64(parts[1]), let outBytes = Int64(parts[2]) else { continue }
            current[pid] = (inBytes, outBytes)

            if let previousCounters = previous[pid] {
                let deltaIn = max(0, inBytes - previousCounters.inBytes)
                let deltaOut = max(0, outBytes - previousCounters.outBytes)
                let delta = deltaIn + deltaOut
                if delta > 0 {
                    deltas[pid] = delta
                }
            }
        }

        return (deltas, current)
    }

    private nonisolated static func getActiveServicesFromConnections(
        processDeltas: [Int32: Int64],
        resolvedIPs: [String: ServiceType]
    ) -> Set<ServiceType> {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-i", "tcp:443", "-n", "-P", "-sTCP:ESTABLISHED"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .utility

        guard let data = runWithTimeout(process, pipe: pipe, timeout: 5) else { return [] }

        guard let output = String(data: data, encoding: .utf8) else { return [] }

        let selfPID = ProcessInfo.processInfo.processIdentifier

        var active: Set<ServiceType> = []
        for line in output.split(separator: "\n") {
            let str = String(line)

            guard let arrowRange = str.range(of: "->"),
                  let colonRange = str.range(of: ":443", options: .backwards, range: arrowRange.upperBound..<str.endIndex)
            else {
                continue
            }

            let parts = str.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count > 1, let pid = Int32(String(parts[1])) else { continue }
            if pid == selfPID { continue }
            let command = String(parts[0])

            let processDelta = processDeltas[pid] ?? 0
            let hasRecentTraffic = processDelta >= minimumProcessDeltaBytes

            if let hinted = hintedService(command: command, pid: pid) {
                if hasRecentTraffic {
                    active.insert(hinted)
                }
                continue
            }

            var ip = String(str[arrowRange.upperBound..<colonRange.lowerBound])
            if ip.hasPrefix("[") { ip.removeFirst() }
            if ip.hasSuffix("]") { ip.removeLast() }

            guard let service = resolvedIPs[ip] else { continue }
            guard shouldCountConnection(command: command, pid: pid, service: service) else { continue }
            guard hasRecentTraffic else { continue }

            active.insert(service)
        }

        return active
    }
}
