import Foundation
import Security

/// Everything needed to restore a Matrix session after relaunch. Mirrors the
/// FFI `Session` record (not Codable) plus our local store secrets.
struct RestorationToken: Codable, Equatable {
    struct SessionData: Codable, Equatable {
        var accessToken: String
        var refreshToken: String?
        var userId: String
        var deviceId: String
        var homeserverUrl: String
        var oauthData: String?
        var slidingSyncVersion: String
    }

    var session: SessionData
    var storePassphrase: String
    var dataPath: String
    var cachePath: String
}

/// Persists restoration tokens (one per account) in the keychain and owns the
/// per-session store directories inside the sandbox container.
struct SessionStore {
    private static let service = "com.rileylopezsantana.Discourse"
    private static let account = "sessions"
    private static let legacyAccount = "activeSession"
    private static let activeUserDefaultsKey = "activeUserId"

    /// Serializes the token array's read-modify-write. OAuth refreshes arrive
    /// on Rust threads and can overlap another save; without this a
    /// load→mutate→save race drops a freshly-rotated refresh token.
    private static let lock = NSLock()

    func loadAll() -> [RestorationToken] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return loadAllLocked()
    }

    private func loadAllLocked() -> [RestorationToken] {
        if let data = read(account: Self.account),
           let tokens = try? JSONDecoder().decode([RestorationToken].self, from: data) {
            return tokens
        }
        // Migrate the single-account format.
        if let data = read(account: Self.legacyAccount),
           let token = try? JSONDecoder().decode(RestorationToken.self, from: data) {
            try? saveAllLocked([token])
            delete(account: Self.legacyAccount)
            return [token]
        }
        return []
    }

    func saveAll(_ tokens: [RestorationToken]) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try saveAllLocked(tokens)
    }

    private func saveAllLocked(_ tokens: [RestorationToken]) throws {
        let data = try JSONEncoder().encode(tokens)
        try write(account: Self.account, data: data)
    }

    /// Read-modify-write the token array under `lock`.
    func mutate(_ transform: ([RestorationToken]) -> [RestorationToken]) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try saveAllLocked(transform(loadAllLocked()))
    }

    func clearAll() {
        Self.lock.lock()
        delete(account: Self.account)
        delete(account: Self.legacyAccount)
        Self.lock.unlock()
        activeUserId = nil
    }

    var activeUserId: String? {
        get { UserDefaults.standard.string(forKey: Self.activeUserDefaultsKey) }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: Self.activeUserDefaultsKey) }
    }

    // MARK: Keychain primitives

    /// Base item query. On iOS the shared access group lets the notification
    /// service extension read the restoration token to restore a client.
    private func baseQuery(account: String) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: account,
        ]
        #if os(iOS)
        if PushConfig.enabled {
            query[kSecAttrAccessGroup] = PushConfig.keychainAccessGroup
        }
        #endif
        return query
    }

    private func read(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private func write(account: String, data: Data) throws {
        let query = baseQuery(account: account)
        // Device-only, after first unlock: secrets never sync to iCloud
        // Keychain but stay readable by a background relaunch. Applied on
        // update too, so older items migrate on the next save.
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    private func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    /// Creates (if needed) and returns the store directories for a session.
    /// `id` is minted at login (before the user ID is known) and persisted in
    /// the restoration token.
    static func makeSessionDirectories(id: String) throws -> (dataPath: String, cachePath: String) {
        let fm = FileManager.default
        let dirName = id
        let dataURL: URL
        let cacheURL: URL
        #if os(iOS)
        // With push on, the store lives in the App Group container so the
        // notification service extension can open it and decrypt. Off, use the
        // normal per-app locations (no App Group entitlement needed).
        if PushConfig.enabled,
           let base = fm.containerURL(forSecurityApplicationGroupIdentifier: PushConfig.appGroup) {
            dataURL = base.appending(path: "Sessions/\(dirName)", directoryHint: .isDirectory)
            cacheURL = base.appending(path: "Caches/\(dirName)", directoryHint: .isDirectory)
        } else {
            let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            dataURL = support.appending(path: "Sessions/\(dirName)", directoryHint: .isDirectory)
            cacheURL = caches.appending(path: "Sessions/\(dirName)", directoryHint: .isDirectory)
        }
        #else
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                 appropriateFor: nil, create: true)
        let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)
        dataURL = support.appending(path: "Sessions/\(dirName)", directoryHint: .isDirectory)
        cacheURL = caches.appending(path: "Sessions/\(dirName)", directoryHint: .isDirectory)
        #endif
        try fm.createDirectory(at: dataURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        return (dataURL.path(percentEncoded: false), cacheURL.path(percentEncoded: false))
    }

    /// Re-resolves a token's store paths against the current container: iOS
    /// relocates the sandbox between installs, so only the directory name is
    /// stable.
    static func currentSessionDirectories(token: RestorationToken) throws -> (dataPath: String, cachePath: String) {
        let id = URL(fileURLWithPath: token.dataPath).lastPathComponent
        return try makeSessionDirectories(id: id)
    }

    static func removeSessionDirectories(token: RestorationToken) {
        let fm = FileManager.default
        if let dirs = try? currentSessionDirectories(token: token) {
            try? fm.removeItem(atPath: dirs.dataPath)
            try? fm.removeItem(atPath: dirs.cachePath)
        }
    }

    static func randomPassphrase() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Should never happen, but the zeroed buffer would key SQLCipher
            // with a predictable value; fall back to the system CSPRNG.
            var rng = SystemRandomNumberGenerator()
            bytes = (0..<bytes.count).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        }
        return Data(bytes).base64EncodedString()
    }
}

struct KeychainError: Error {
    let status: OSStatus
}
