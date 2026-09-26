import Foundation
import Security

/// Reads a Keychain item through `/usr/bin/security` — the tool that wrote it.
///
/// Claude Code, and Orca for the logins it manages, store credentials with the
/// `security` command-line tool, so each item's ACL trusts that tool and its
/// partition list admits Apple's own tools. Asking through the same tool is
/// silent by construction — no grant, no dialog, however this app is signed.
/// It is how Claude Code reads its own login.
///
/// The item's access list is checked first, from metadata alone: asking the tool
/// for an item it isn't trusted with, or one in a locked keychain, would raise
/// the very dialog this exists to avoid, with "security" as the name on it.
enum SecurityToolReader {
    private static let tool = "/usr/bin/security"

    static func read(service: String, account: String) -> String? {
        guard toolReadsSilently(service: service, account: account) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // It answers in milliseconds; one still running has hung, not thought.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if process.isRunning { process.terminate() }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        // A secret the tool deems unprintable comes out as hex.
        if !text.hasPrefix("{"), let bytes = Data(hexString: text),
           let decoded = String(data: bytes, encoding: .utf8), decoded.hasPrefix("{") {
            return decoded
        }
        return text
    }

    /// Whether the tool can read the item without anything asking: its keychain
    /// is unlocked, a decrypt entry of its ACL trusts the tool (or any app)
    /// without a confirmation, and its partition list admits Apple's tools.
    private static func toolReadsSilently(service: String, account: String) -> Bool {
        let query = KeychainSilence.readQuery([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ])
        return KeychainSilence.run {
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let ref = result, CFGetTypeID(ref) == SecKeychainItemGetTypeID() else { return false }
            let item = ref as! SecKeychainItem

            var keychain: SecKeychain?
            var status = SecKeychainStatus()
            guard SecKeychainItemCopyKeychain(item, &keychain) == errSecSuccess, let keychain,
                  SecKeychainGetStatus(keychain, &status) == errSecSuccess,
                  status & SecKeychainStatus(kSecUnlockStateStatus) != 0 else { return false }

            var access: SecAccess?
            var list: CFArray?
            guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess, let access,
                  SecAccessCopyACLList(access, &list) == errSecSuccess,
                  let entries = list as? [SecACL] else { return false }

            var trusted = false
            var partitionAdmits = true  // items from before partition lists carry none
            for entry in entries {
                let authorizations = SecACLCopyAuthorizations(entry) as? [String] ?? []
                var apps: CFArray?
                var description: CFString?
                var selector = SecKeychainPromptSelector()
                guard SecACLCopyContents(entry, &apps, &description, &selector) == errSecSuccess else { continue }

                if authorizations.contains(kSecACLAuthorizationPartitionID as String) {
                    partitionAdmits = partitions(in: description as String?)
                        .contains { $0 == "apple-tool:" || $0 == "apple:" }
                } else if authorizations.contains(kSecACLAuthorizationDecrypt as String)
                            || authorizations.contains(kSecACLAuthorizationAny as String),
                          !selector.contains(.requirePassphase) {
                    // No application list at all means any application.
                    guard let apps = apps as? [SecTrustedApplication] else { trusted = true; continue }
                    if apps.contains(where: { path(of: $0) == tool }) { trusted = true }
                }
            }
            return trusted && partitionAdmits
        }
    }

    private static func path(of app: SecTrustedApplication) -> String? {
        var data: CFData?
        guard SecTrustedApplicationCopyData(app, &data) == errSecSuccess, let bytes = data as Data? else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// The partition list rides in the entry's description as a hex-encoded plist.
    private static func partitions(in description: String?) -> [String] {
        guard let description, let data = Data(hexString: description),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [] }
        return plist["Partitions"] as? [String] ?? []
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
