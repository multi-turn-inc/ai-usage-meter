import AppKit
import SwiftUI

struct AuthErrorView: View {
    let service: ServiceViewModel
    var onRefresh: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.system(size: 14))
                    .modifier(PulseEffect())

                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button(action: startBrowserLogin) {
                    HStack(spacing: 6) {
                        if isLoggingIn {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "globe")
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

    private var errorMessage: String {
        if let error = service.lastError {
            let lower = error.lowercased()
            if lower.contains("scope") || lower.contains("permission") {
                return "토큰 권한이 부족합니다. 로그아웃 후 재로그인해주세요."
            }
            if lower.contains("만료") || lower.contains("expired") || lower.contains("revoke") {
                return "토큰이 만료되었습니다. 재로그인해주세요."
            }
        }
        switch service.config.serviceType {
        case .claude: return "Claude 인증이 필요합니다."
        case .gemini: return "Gemini 인증이 필요합니다."
        case .codex: return "Codex 인증이 필요합니다."
        }
    }

    private var buttonLabel: String {
        switch service.config.serviceType {
        case .claude: return "브라우저로 로그인"
        case .gemini: return "gemini 인증"
        case .codex: return "브라우저로 로그인"
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
