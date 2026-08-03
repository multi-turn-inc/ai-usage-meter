import Foundation
import AIUsageMeterCore

/// Re-authenticates an account by driving the provider's CLI **headlessly**, so
/// the user only ever sees the browser page — no Terminal window.
///
/// This is how Orca does it, and the reason is worth stating: neither Claude nor
/// Codex exposes a public OAuth client an outside app may drive itself. Their
/// CLIs already implement the whole flow (PKCE, a localhost callback server,
/// opening the browser), so the reliable move is to run the CLI as a plain child
/// process with the account's config home in the environment and let it own the
/// handshake. It opens the browser; we just wait.
@MainActor
@Observable
final class CLILoginLauncher {
    static let shared = CLILoginLauncher()

    /// Account ids currently running a login, so the button can show progress.
    private(set) var inFlight: Set<String> = []
    private(set) var lastError: String?

    private var processes: [String: Process] = [:]

    private init() {}

    func isRunning(_ accountID: String?) -> Bool {
        guard let accountID else { return false }
        return inFlight.contains(accountID)
    }

    /// Starts the browser login. Returns immediately; completion arrives via
    /// `onFinished` once the CLI exits.
    func login(service: ServiceType, account: ProviderAccount?, onFinished: @escaping () -> Void) {
        let key = account?.id ?? "default:\(service.rawValue)"
        guard !inFlight.contains(key) else { return }

        guard let executable = Self.locateCLI(for: service) else {
            lastError = "\(Self.commandName(for: service)) 명령을 찾을 수 없습니다"
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Self.loginArguments(for: service, account: account)

        var environment = ProcessInfo.processInfo.environment
        // Point the CLI at *this* account's home so a multi-account machine
        // re-authenticates the row the user clicked, not the default login.
        if let configDir = account?.configDir {
            switch service {
            case .claude: environment["CLAUDE_CONFIG_DIR"] = configDir
            case .codex: environment["CODEX_HOME"] = configDir
            case .gemini: break
            }
        }
        // A login launched from a LaunchAgent inherits almost no PATH; the CLIs
        // shell out to open the browser and to node, so give them a usable one.
        environment["PATH"] = Self.searchPaths.joined(separator: ":")
            + ":" + (environment["PATH"] ?? "")
        process.environment = environment

        // Claude's browser auth ties its callback server's lifetime to stdin —
        // closing it tears the server down before the browser comes back.
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.inFlight.remove(key)
                self?.processes[key] = nil
                // The CLI just rewrote this account's credentials. Pick them up
                // now, while the user is still here and a Keychain grant is in
                // context — only discarding our copy would leave the account with
                // nothing readable, so a completed login would show up as an
                // authentication failure.
                if let account { AccountCredentialStore.shared.reimport(account) }
                onFinished()
            }
        }

        do {
            try process.run()
            processes[key] = process
            inFlight.insert(key)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func cancel(accountID: String) {
        processes[accountID]?.terminate()
        processes[accountID] = nil
        inFlight.remove(accountID)
    }

    // MARK: - CLI resolution

    private static let searchPaths = [
        "/opt/homebrew/bin", "/usr/local/bin",
        NSHomeDirectory() + "/.local/bin",
        NSHomeDirectory() + "/.bun/bin",
        "/usr/bin", "/bin",
    ]

    static func commandName(for service: ServiceType) -> String {
        switch service {
        case .claude: return "claude"
        case .codex: return "codex"
        case .gemini: return "gemini"
        }
    }

    /// `claude auth login` / `codex login` run the browser handshake and exit,
    /// unlike a bare invocation which would sit in an interactive session.
    ///
    /// The email is pre-filled when known: on a machine with several logins the
    /// easiest mistake is re-authenticating the wrong one, which would overwrite
    /// a working account's credentials with a different identity.
    static func loginArguments(for service: ServiceType, account: ProviderAccount?) -> [String] {
        switch service {
        case .claude:
            var args = ["auth", "login", "--claudeai"]
            if let email = account?.email, !email.isEmpty {
                args += ["--email", email]
            }
            return args
        case .codex:
            return ["login"]
        case .gemini:
            return []
        }
    }

    /// Searches the usual install locations plus any node version-manager shims,
    /// since a LaunchAgent's PATH won't include them.
    static func locateCLI(for service: ServiceType) -> String? {
        let name = commandName(for: service)
        let fm = FileManager.default

        for directory in searchPaths {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }

        // nvm keeps binaries under ~/.nvm/versions/node/<version>/bin.
        let nvm = NSHomeDirectory() + "/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvm) {
            for version in versions.sorted().reversed() {
                let candidate = "\(nvm)/\(version)/bin/\(name)"
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }
}
