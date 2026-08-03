import Foundation
import AIUsageMeterCore

/// Which discovered accounts the user actually wants on screen, plus adding new
/// ones.
///
/// Accounts are *discovered*, not created, so "remove" can't mean deleting
/// someone's login — it hides the row. The one exception is an account this app
/// added itself, which owns its config home and can be deleted outright.
@MainActor
@Observable
final class AccountRegistry {
    static let shared = AccountRegistry()

    private let hiddenKey = "hiddenAccountIDs"

    private(set) var hidden: Set<String> {
        didSet { AppDefaults.userDefaults.set(Array(hidden), forKey: hiddenKey) }
    }

    private init() {
        hidden = Set(AppDefaults.userDefaults.stringArray(forKey: hiddenKey) ?? [])
    }

    func isHidden(_ accountID: String) -> Bool { hidden.contains(accountID) }

    func setHidden(_ isHidden: Bool, for accountID: String) {
        if isHidden { hidden.insert(accountID) } else { hidden.remove(accountID) }
    }

    /// Accounts to monitor, in discovery order.
    func visibleAccounts() -> [ProviderAccount] {
        AccountDiscovery.discover().filter { !hidden.contains($0.id) }
    }

    func allAccounts() -> [ProviderAccount] { AccountDiscovery.discover() }

    /// True when this app owns the account's config home and can delete it.
    func canDelete(_ account: ProviderAccount) -> Bool {
        account.id.contains(":own:")
    }

    /// Deletes a self-managed account's config home. Only ever touches homes
    /// under our own directory — never the CLI's or another app's.
    func delete(_ account: ProviderAccount) {
        guard canDelete(account), let dir = account.configDir else { return }
        let root = AccountDiscovery.selfManagedRoot(
            home: FileManager.default.homeDirectoryForCurrentUser
        ).path
        guard dir.hasPrefix(root + "/") else { return }
        try? FileManager.default.removeItem(atPath: dir)
        hidden.remove(account.id)
        AccountCredentialStore.shared.forget(account)
    }

    /// Creates an empty config home and runs the provider's browser login into
    /// it. The resulting credentials land in a file this app owns, so the new
    /// account reads without a Keychain prompt.
    func addAccount(service: ServiceType, onFinished: @escaping () -> Void) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = AccountDiscovery.newSelfManagedDir(for: service, home: home)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        // A placeholder account carrying just the config home — enough for the
        // launcher to point the CLI at the right place.
        let pending = ProviderAccount(
            id: "pending:\(dir.lastPathComponent)",
            service: service,
            email: nil,
            organizationName: nil,
            identityKey: dir.path,
            source: .file(path: dir.appendingPathComponent(".credentials.json").path),
            isDefault: false,
            configDir: dir.path
        )

        CLILoginLauncher.shared.login(service: service, account: pending) { [weak self] in
            // Nothing was written if the user abandoned the browser flow; don't
            // leave an empty home behind to be rediscovered as a broken account.
            self?.discardIfEmpty(dir, service: service)
            onFinished()
        }
    }

    private func discardIfEmpty(_ dir: URL, service: ServiceType) {
        let marker = switch service {
        case .claude: dir.appendingPathComponent(".credentials.json")
        case .codex: dir.appendingPathComponent("auth.json")
        case .gemini: dir
        }
        if !FileManager.default.fileExists(atPath: marker.path) {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}
