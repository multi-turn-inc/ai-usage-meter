import Foundation

final class ProcessMonitor {
    static let shared = ProcessMonitor()

    private(set) var activeServices: Set<ServiceType> = []

    private var timer: Timer?
    private let pollInterval: TimeInterval = 5

    private let apiEndpoints: [(host: String, service: ServiceType)] = [
        ("api.anthropic.com", .claude),
        ("api.openai.com", .codex),
        ("chatgpt.com", .codex),
        ("generativelanguage.googleapis.com", .gemini),
    ]

    private var resolvedIPs: [String: ServiceType] = [:]
    private var pollCount = 0
    private var lastProcessCounters: [Int32: (inBytes: Int64, outBytes: Int64)] = [:]
    private var lastActiveAt: [ServiceType: Date] = [:]

    private let minimumProcessDeltaBytes: Int64 = 4096
    private let activityGraceInterval: TimeInterval = 4

    private init() {}

    func start() {
        stop()
        lastProcessCounters.removeAll()
        lastActiveAt.removeAll()
        resolveAllHosts()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        activeServices = []
        lastProcessCounters.removeAll()
        lastActiveAt.removeAll()
    }

    func isActive(_ serviceType: ServiceType) -> Bool {
        activeServices.contains(serviceType)
    }

    private func poll() {
        let processDeltas = sampleProcessDeltas()
        var newActive = getActiveServicesFromConnections(processDeltas: processDeltas)

        let now = Date()
        for service in newActive {
            lastActiveAt[service] = now
        }

        for service in ServiceType.allCases where !newActive.contains(service) {
            if let lastSeen = lastActiveAt[service], now.timeIntervalSince(lastSeen) < activityGraceInterval {
                newActive.insert(service)
            }
        }

        if newActive != activeServices {
            activeServices = newActive
        }

        pollCount += 1
        if pollCount % 60 == 0 {
            resolveAllHosts()
        }
    }

    private func resolveAllHosts() {
        var newIPs: [String: ServiceType] = [:]
        for (host, service) in apiEndpoints {
            for ip in resolveHost(host) {
                newIPs[ip] = service
            }
        }
        self.resolvedIPs = newIPs
    }

    private func resolveHost(_ hostname: String) -> [String] {
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

    private func shouldCountConnection(command: String, pid: Int32, service: ServiceType) -> Bool {
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

    private func hintedService(command: String, pid: Int32) -> ServiceType? {
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

    private func runWithTimeout(_ process: Process, pipe: Pipe, timeout: TimeInterval = 5) -> Data? {
        do { try process.run() } catch { return nil }
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    private func commandLine(for pid: Int32) -> String? {
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

    private func sampleProcessDeltas() -> [Int32: Int64] {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .utility

        guard let data = runWithTimeout(process, pipe: pipe, timeout: 5) else { return [:] }

        guard let output = String(data: data, encoding: .utf8) else { return [:] }

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

            if let previous = lastProcessCounters[pid] {
                let deltaIn = max(0, inBytes - previous.inBytes)
                let deltaOut = max(0, outBytes - previous.outBytes)
                let delta = deltaIn + deltaOut
                if delta > 0 {
                    deltas[pid] = delta
                }
            }
        }

        lastProcessCounters = current
        return deltas
    }

    private func getActiveServicesFromConnections(processDeltas: [Int32: Int64]) -> Set<ServiceType> {
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
