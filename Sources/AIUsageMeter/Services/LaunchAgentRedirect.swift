import Foundation
import AppKit

/// macOS 26 workaround: an `NSStatusItem` created by the binary running *inside* the
/// `.app` bundle (e.g. a double-click in /Applications) never appears in the menu bar.
/// The exact same binary shows the icon fine when launched from outside a bundle, so we
/// install a standalone copy under Application Support and run it via a LaunchAgent.
///
/// This helper detects the in-bundle launch, self-installs the standalone copy + LaunchAgent
/// (so a fresh DMG install works on the very first double-click, with no build script), starts
/// it, and signals the caller to quit the in-bundle instance.
@MainActor
enum LaunchAgentRedirect {
    static let agentLabel = "com.tokenburn.agent"

    private static var installDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TokenBurn", isDirectory: true)
    }

    private static var standaloneBinary: URL {
        installDir.appendingPathComponent("AIUsageMeter")
    }

    private static var plistPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    /// True when the running binary lives inside a `.app` bundle (i.e. a double-click launch).
    /// The standalone copy launched by launchd lives outside any bundle, so it returns false
    /// and never redirects again — no launch loop.
    static func shouldRedirect() -> Bool {
        guard let exec = Bundle.main.executablePath else { return false }
        return exec.contains(".app/Contents/MacOS/")
    }

    /// Sync the standalone binary, (re)install the LaunchAgent, and start it.
    /// Returns true if the standalone instance was started (caller should then quit).
    static func redirectAndStart() -> Bool {
        let uid = getuid()
        let domainTarget = "gui/\(uid)"
        let serviceTarget = "gui/\(uid)/\(agentLabel)"

        // Stop any running standalone instance so its binary can be replaced cleanly.
        _ = runLaunchctl(["bootout", serviceTarget])

        guard syncStandaloneBinary() else { return false }
        writePlist()

        // bootstrap loads the agent; RunAtLoad starts it immediately.
        // If it was already loaded (bootout raced/failed), fall back to a forced restart.
        if runLaunchctl(["bootstrap", domainTarget, plistPath.path]) {
            return true
        }
        return runLaunchctl(["kickstart", "-k", serviceTarget])
    }

    /// Copy the current bundle's binary (and the Sparkle framework it links against) to the
    /// standalone location, mirroring the layout `build-app.sh` produces. Quarantine is cleared
    /// so launchd can start the notarized copy without a Gatekeeper prompt.
    private static func syncStandaloneBinary() -> Bool {
        let fm = FileManager.default
        guard let bundleExec = Bundle.main.executablePath else { return false }

        do {
            try fm.createDirectory(at: installDir, withIntermediateDirectories: true)

            try? fm.removeItem(at: standaloneBinary)
            try fm.copyItem(atPath: bundleExec, toPath: standaloneBinary.path)

            // The binary links Sparkle via an @loader_path rpath, so the framework must sit
            // beside the binary for dyld to resolve it.
            if let frameworks = Bundle.main.privateFrameworksURL {
                let sparkleSrc = frameworks.appendingPathComponent("Sparkle.framework")
                if fm.fileExists(atPath: sparkleSrc.path) {
                    let sparkleDst = installDir.appendingPathComponent("Sparkle.framework")
                    try? fm.removeItem(at: sparkleDst)
                    try fm.copyItem(at: sparkleSrc, to: sparkleDst)
                }
            }
        } catch {
            return false
        }

        // The in-bundle signature seals the bundle's Info.plist, so the copied binary fails
        // signature validation ("invalid Info.plist") and is SIGKILLed. Re-sign ad-hoc with no
        // hardened runtime — this drops the bundle reference and disables library validation so
        // the Developer ID-signed Sparkle.framework still loads, matching build-app.sh's layout.
        guard adhocSign(standaloneBinary) else { return false }

        clearQuarantine(at: installDir)
        return true
    }

    private static func adhocSign(_ url: URL) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["--force", "--sign", "-", url.path]
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func writePlist() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(agentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(standaloneBinary.path)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <false/>
        </dict>
        </plist>
        """
        let dir = plistPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? plist.write(to: plistPath, atomically: true, encoding: .utf8)
    }

    private static func clearQuarantine(at url: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-dr", "com.apple.quarantine", url.path]
        try? task.run()
        task.waitUntilExit()
    }

    @discardableResult
    private static func runLaunchctl(_ args: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}
