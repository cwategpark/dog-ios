import Foundation
#if canImport(Security)
import Security
#endif

/// Token 持久化抽象：access + refresh 成对保存/读取/清空。
///
/// - App 内使用 `KeychainTokenStore`（Security.framework）；
/// - 测试使用 `InMemoryTokenStore`，不碰真实钥匙串。
public protocol TokenStoring: AnyObject {
    func load() -> TokenBundle?
    func save(_ bundle: TokenBundle) throws
    func clear()
}

// MARK: - 内存测试替身

/// 线程安全的内存 token 存储，供单元测试与预览使用。
public final class InMemoryTokenStore: TokenStoring {
    private let lock = NSLock()
    private var bundle: TokenBundle?

    public init(bundle: TokenBundle? = nil) {
        self.bundle = bundle
    }

    public func load() -> TokenBundle? {
        lock.lock()
        defer { lock.unlock() }
        return bundle
    }

    public func save(_ bundle: TokenBundle) throws {
        lock.lock()
        defer { lock.unlock() }
        self.bundle = bundle
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        bundle = nil
    }

    public var currentAccessToken: String? { load()?.accessToken }
}

// MARK: - Keychain

public enum KeychainTokenStoreError: Error, Equatable, LocalizedError {
    case encodingFailed
    case unhandledStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "token 编码失败"
        case .unhandledStatus(let status):
            return "Keychain 操作失败（OSStatus=\(status)）"
        }
    }
}

/// 用 Keychain（`kSecClassGenericPassword`）持久化 token；service 可配置。
///
/// 整个 `TokenBundle` 以 JSON 存一条 generic password，access/refresh 一起轮换，
/// 避免两把钥匙不同步。App 卸载即清除；`ThisDeviceOnly` 不随 iCloud 迁移（iOS）。
public final class KeychainTokenStore: TokenStoring {
    public let service: String
    public let account: String

    private let encoder = DogiosJSON.makeEncoder()
    private let decoder = DogiosJSON.makeDecoder()

    public init(service: String = "app.pawly.dogios.tokens",
                account: String = "dogios.token_bundle") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    public func load() -> TokenBundle? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let bundle = try? decoder.decode(TokenBundle.self, from: data) else {
            return nil
        }
        return bundle
    }

    public func save(_ bundle: TokenBundle) throws {
        guard let data = try? encoder.encode(bundle) else {
            throw KeychainTokenStoreError.encodingFailed
        }
        let query = baseQuery
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainTokenStoreError.unhandledStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainTokenStoreError.unhandledStatus(addStatus)
        }
    }

    public func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
