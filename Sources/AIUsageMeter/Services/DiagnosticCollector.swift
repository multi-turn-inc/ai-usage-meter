import Foundation
import Security

enum DiagnosticCollector {
    static func collect() -> String {
        var lines: [String] = []

        // App
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        lines.append("App: v\(appVersion)")

        // macOS
        let os = ProcessInfo.processInfo.operatingSystemVersion
        lines.append("macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")

        // Locale
        lines.append("Locale: \(Locale.current.identifier)")

        // Claude Code version
        let claudeVersion = shellOutput("claude --version") ?? "not found"
        lines.append("Claude Code: \(claudeVersion)")

        // Keychain credentials
        let creds = KeychainManager.shared.getClaudeCodeCredentials(allowInteraction: false)
        if let creds {
            lines.append("Token: \(creds.isExpired ? "expired" : "valid")")
            if let tier = creds.rateLimitTier {
                lines.append("Tier: \(tier)")
            }
            if let scopes = creds.scopes {
                lines.append("Scopes: \(scopes.joined(separator: ", "))")
            }
        } else {
            lines.append("Token: not found")
        }

        // Credential file paths
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let credPaths = [
            "\(home)/.claude/.credentials.json",
            "\(home)/.config/claude/.credentials.json",
            "\(home)/.config/claude-code/.credentials.json"
        ]
        let existingFiles = credPaths.filter { FileManager.default.fileExists(atPath: $0) }
        lines.append("Cred files: \(existingFiles.isEmpty ? "none" : existingFiles.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))")

        // Keychain entries count
        let entryCount = countKeychainEntries()
        lines.append("Keychain entries: \(entryCount)")

        return lines.joined(separator: "\n")
    }

    /// Escapes the five characters that are unsafe inside HTML text/attribute
    /// contexts. Applied to shell output before inserting into the bug-report
    /// email body so a hostile `claude --version` payload can't break out of
    /// the surrounding `<pre>` and inject markup.
    static func htmlEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            case "\"": out.append("&quot;")
            case "'": out.append("&#39;")
            default: out.append(ch)
            }
        }
        return out
    }

    private static func shellOutput(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        // Pin PATH so the child process resolves `claude` etc. from known
        // Homebrew/system locations only; ignore the parent env.
        process.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = DispatchTime.now() + 3
        DispatchQueue.global().asyncAfter(deadline: deadline) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func countKeychainEntries() -> Int {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let items = result as? [[String: Any]] {
            return items.count
        }
        return 0
    }
}
