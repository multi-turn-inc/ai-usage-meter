import Foundation
#if canImport(AppKit)
import AppKit
#endif

#if ENABLE_SPARKLE && canImport(Sparkle)
import Sparkle

@MainActor
final class SparkleUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?

    override init() {
        super.init()
        guard Self.isProperAppBundle() else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? true }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    private static func isProperAppBundle() -> Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }
}
#endif

@MainActor
@Observable
class Updater {
    static let shared = Updater()

    #if ENABLE_SPARKLE && canImport(Sparkle)
    let sparkle = SparkleUpdater()
    #endif

    var updateAvailable = false
    var latestVersion: String?
    var isUpdating = false
    var error: String?

    private let githubRepo = "multi-turn-inc/ai-usage-meter"
    private var autoCheckTimer: Timer?

    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        ?? "4.2.0"

    private var currentVersion: String { Self.appVersion }

    private init() {
        // Auto-check on launch (after 5 seconds) + every 4 hours
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.autoCheck()
        }
        autoCheckTimer = Timer.scheduledTimer(withTimeInterval: 4 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autoCheck() }
        }
    }

    func checkForUpdates() {
        #if ENABLE_SPARKLE && canImport(Sparkle)
        if sparkle.canCheckForUpdates {
            sparkle.checkForUpdates()
            return
        }
        #endif
        Task { await checkAndApply(userInitiated: true) }
    }

    private func autoCheck() {
        #if ENABLE_SPARKLE && canImport(Sparkle)
        // Sparkle handles its own auto-check
        if sparkle.canCheckForUpdates { return }
        #endif
        Task { await checkAndApply(userInitiated: false) }
    }

    private func checkAndApply(userInitiated: Bool) async {
        let url = URL(string: "https://api.github.com/repos/\(githubRepo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String else {
            if userInitiated { error = "Failed to check for updates" }
            return
        }

        let latest = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        latestVersion = latest
        let hasUpdate = compareVersions(current: currentVersion, latest: latest)
        updateAvailable = hasUpdate

        if hasUpdate {
            if userInitiated {
                // User clicked: auto-download and apply
                await downloadAndApply(from: json, version: latest)
            }
            // Auto-check just sets the flag; user sees it in settings
        } else if userInitiated {
            openURL("https://github.com/\(githubRepo)/releases/latest")
        }
    }

    private func downloadAndApply(from json: [String: Any], version: String) async {
        guard let urlString = preferredDownloadURL(from: json),
              let url = URL(string: urlString) else {
            openURL("https://github.com/\(githubRepo)/releases/latest")
            return
        }

        isUpdating = true
        defer { isUpdating = false }

        do {
            let (tempURL, _) = try await URLSession.shared.download(from: url)
            let installDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/TokenBurn")

            // Mount DMG, extract binary
            let mountPoint = "/tmp/TokenBurnUpdate"
            try? FileManager.default.removeItem(atPath: mountPoint)

            let mount = Process()
            mount.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            mount.arguments = ["attach", tempURL.path, "-mountpoint", mountPoint, "-nobrowse", "-quiet"]
            try mount.run()
            mount.waitUntilExit()

            guard mount.terminationStatus == 0 else {
                // Fallback: open DMG manually
                openURL(urlString)
                return
            }

            defer {
                let detach = Process()
                detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                detach.arguments = ["detach", mountPoint, "-quiet"]
                try? detach.run()
                detach.waitUntilExit()
            }

            // Find the binary inside the .app in the DMG
            let appName = "Token Burn.app"
            let binaryPath = "\(mountPoint)/\(appName)/Contents/MacOS/AIUsageMeter"

            guard FileManager.default.fileExists(atPath: binaryPath) else {
                openURL(urlString)
                return
            }

            // Replace binary
            let destPath = installDir.appendingPathComponent("AIUsageMeter").path
            let backupPath = destPath + ".bak"
            try? FileManager.default.removeItem(atPath: backupPath)
            try? FileManager.default.moveItem(atPath: destPath, toPath: backupPath)
            try FileManager.default.copyItem(atPath: binaryPath, toPath: destPath)

            // Copy Sparkle framework too
            let sparkleSource = "\(mountPoint)/\(appName)/Contents/Frameworks/Sparkle.framework"
            let sparkleDest = installDir.appendingPathComponent("Sparkle.framework")
            if FileManager.default.fileExists(atPath: sparkleSource) {
                try? FileManager.default.removeItem(at: sparkleDest)
                try? FileManager.default.copyItem(atPath: sparkleSource, toPath: sparkleDest.path)
            }

            // Clean up backup
            try? FileManager.default.removeItem(atPath: backupPath)

            updateAvailable = false
            latestVersion = version

            // Restart the app
            let binary = destPath
            let task = Process()
            task.executableURL = URL(fileURLWithPath: binary)
            task.arguments = []
            try task.run()

            // Exit current instance
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.terminate(nil)
            }
        } catch {
            self.error = error.localizedDescription
            openURL(urlString)
        }
    }

    private nonisolated func compareVersions(current: String, latest: String) -> Bool {
        let c = current.split(separator: ".").compactMap { Int($0) }
        let l = latest.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(c.count, l.count) {
            let cv = i < c.count ? c[i] : 0
            let lv = i < l.count ? l[i] : 0
            if lv > cv { return true }
            if lv < cv { return false }
        }
        return false
    }

    private nonisolated func preferredDownloadURL(from json: [String: Any]) -> String? {
        guard let assets = json["assets"] as? [[String: Any]] else { return nil }
        return assets.first {
            ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true
        }?["browser_download_url"] as? String
    }

    private func openURL(_ rawURL: String) {
        guard let url = URL(string: rawURL) else { return }
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}
