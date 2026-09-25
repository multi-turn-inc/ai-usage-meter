import AppKit
import SwiftUI

struct AuthErrorView: View {
    let service: ServiceViewModel
    var onRefresh: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: isRateLimited ? "clock.badge" : "exclamationmark.triangle.fill")
                    .foregroundStyle(isRateLimited ? Color.secondary : Color.yellow)
                    .font(.system(size: 14))
                    .modifier(PulseEffect())

                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                // A missing Keychain grant is fixed by retrying with UI allowed,
                // not by signing in again — offering "log in" there would throw
                // away a perfectly good credential.
                Button(action: (needsKeychainGrant || isRateLimited) ? { onRefresh?() } : startBrowserLogin) {
                    HStack(spacing: 6) {
                        if isLoggingIn {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: isRateLimited ? "clock.arrow.circlepath"
                                                : (needsKeychainGrant ? "key.fill" : "globe"))
                                .font(.system(size: 11))
                        }
                        Text(isLoggingIn ? "브라우저에서 로그인 중…" : buttonLabel)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.glass)
                .disabled(isLoggingIn)

                if let onRefresh {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    private var needsLogout: Bool {
        guard let error = service.lastError?.lowercased() else { return false }
        return error.contains("scope") || error.contains("permission") || error.contains("403")
            || error.contains("/logout")
    }

    /// This account's credentials sit in another app's Keychain item, so the
    /// first read needs a one-time grant rather than a fresh login.
    private var needsKeychainGrant: Bool {
        service.lastError?.contains("키체인") == true
    }

    /// Throttled by the provider — nothing is wrong with the credentials, so
    /// offering a re-login here would be actively misleading.
    private var isRateLimited: Bool {
        service.lastError?.lowercased().contains("rate limit") == true
    }

    private var errorMessage: String {
        if isRateLimited {
            return "요청이 많아 잠시 후 자동으로 다시 시도합니다."
        }
        if needsKeychainGrant {
            return "키체인 접근을 한 번 허용하면 계속 표시됩니다."
        }
        if let error = service.lastError {
            let lower = error.lowercased()
            if lower.contains("scope") || lower.contains("permission") {
                return "토큰 권한이 부족합니다. 로그아웃 후 재로그인해주세요."
            }
            // Say what actually went wrong. These messages already distinguish a
            // login this app can renew from one only another app can, and which
            // account is involved — rewriting them all into "authentication
            // required" sent the user to a re-login that often fixed nothing.
            if !stripped(error).isEmpty { return stripped(error) }
        }
        switch service.config.serviceType {
        case .claude: return "Claude 인증이 필요합니다."
        case .gemini: return "Gemini 인증이 필요합니다."
        case .codex: return "Codex 인증이 필요합니다."
        }
    }

    /// Drops what the card already says or no one needs to read: the
    /// transport's "HTTP error 401: " and the leading account label.
    private func stripped(_ error: String) -> String {
        var message = error
        if let range = message.range(of: #"^HTTP error \d+: "#, options: .regularExpression) {
            message.removeSubrange(range)
        }
        if let label = service.account?.label, message.hasPrefix("\(label): ") {
            message = String(message.dropFirst(label.count + 2))
        }
        return message
    }

    private var buttonLabel: String {
        if isRateLimited { return "다시 시도" }
        if needsKeychainGrant { return "키체인 접근 허용" }
        switch service.config.serviceType {
        case .claude, .codex: return "브라우저로 로그인"
        case .gemini: return "gemini 인증"
        }
    }

    private var isLoggingIn: Bool {
        CLILoginLauncher.shared.isRunning(service.account?.id
            ?? "default:\(service.config.serviceType.rawValue)")
    }

    /// Runs the provider CLI's own browser login as a hidden child process, so
    /// the user sees the web page and never a Terminal window. Gemini has no
    /// non-interactive login, so it still gets a terminal.
    private func startBrowserLogin() {
        let type = service.config.serviceType
        guard type != .gemini else { return openTerminalForGemini() }

        CLILoginLauncher.shared.login(service: type, account: service.account) {
            onRefresh?()
        }
    }

    private func openTerminalForGemini() {
        let scriptPath = NSTemporaryDirectory() + "aimonitor-reauth-\(UUID().uuidString).command"
        let script = "#!/bin/bash\necho '🔄 재인증 중...'\ngemini\necho ''\necho '✅ 완료! 이 창을 닫아도 됩니다.'\nread -p ''\n"
        try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        NSWorkspace.shared.open(URL(fileURLWithPath: scriptPath))
    }
}
