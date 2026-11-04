import SwiftUI
import CryptoKit
#if canImport(DogiosDataLayer)
import DogiosDataLayer
#endif

@MainActor
final class MobileAppStore: ObservableObject {
    @Published var me: MobileMeResponse?
    @Published var starting = true
    @Published var startupError: String?
    @Published var sessionID = UUID()
    @Published var discovery: DiscoveryStatus?
    private var profileOperation = UUID()
    let client: MobileAPIClient?
    let configurationError: String?
    var identity: IdentityService? { client.map(IdentityService.init) }
    var assets: AssetService? { client.map(AssetService.init) }
    var homes: PetHomeService? { client.map(PetHomeService.init) }
    var contacts: ContactService? { client.map(ContactService.init) }
    var messages: MessageService? { client.map(MessageService.init) }
    var discoveryService: DiscoveryService? { client.map(DiscoveryService.init) }

    init(client suppliedClient: MobileAPIClient? = nil) {
        if let suppliedClient {
            client = suppliedClient
            configurationError = nil
            return
        }
        do {
            client = MobileAPIClient(config: try AppConfig())
            configurationError = nil
        } catch {
            client = nil
            configurationError = error.localizedDescription
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-test-reset-session") {
            client?.clearSession()
        }
        #endif
    }

    func bootstrap() async {
        let operation = UUID()
        profileOperation = operation
        starting = true
        startupError = nil
        defer { if profileOperation == operation { starting = false } }
        guard let identity, let client else {
            startupError = configurationError
            return
        }
        guard identity.isAuthenticated else {
            me = nil
            discovery = nil
            return
        }
        let generation = client.sessionGeneration
        do {
            let profile = try await identity.me()
            guard profileOperation == operation, client.sessionGeneration == generation,
                  !Task.isCancelled else { return }
            me = profile
        } catch {
            guard profileOperation == operation, client.sessionGeneration == generation,
                  !Task.isCancelled else { return }
            if !handleSessionError(error) { startupError = friendly(error) }
        }
    }

    func finishLogin() async throws {
        guard let identity, let client else { throw MobileAPIError.invalidResponse("服务地址未配置") }
        let operation = UUID()
        profileOperation = operation
        let generation = client.sessionGeneration
        let profile = try await identity.me()
        guard profileOperation == operation, client.sessionGeneration == generation,
              !Task.isCancelled else { throw MobileAPIError.cancelled() }
        let changedAccount = me?.userId != profile.userId
        me = profile
        startupError = nil
        if changedAccount { sessionID = UUID() }
    }

    @discardableResult
    func handleSessionError(_ error: Error) -> Bool {
        guard let api = error as? MobileAPIError, api.isUnauthorized,
              let generation = api.sessionGeneration,
              client?.clearSession(ifGeneration: generation) == true else { return false }
        clearPrivateState()
        return true
    }

    private func clearPrivateState() {
        profileOperation = UUID()
        starting = false
        me = nil
        discovery = nil
        startupError = nil
        sessionID = UUID()
        URLCache.shared.removeAllCachedResponses()
    }

    func logout() async {
        let service = identity
        // Invalidate both transport and view generations before the first await.
        let captured = client?.takeSessionForLogout()
        clearPrivateState()
        try? await service?.revokeSession(captured)
    }

    func friendly(_ error: Error) -> String {
        if let api = error as? MobileAPIError {
            if api.code == "invalid_otp" { return "验证码不正确或已过期，请重试。" }
            switch api.kind {
            case .unauthorized: return "登录已过期，请重新验证邮箱。"
            case .network, .unavailable, .server: return "暂时连不上服务，请稍后重试。"
            case .rateLimited:
                return "操作较频繁，请在 \(Int(api.retryAfter ?? 60)) 秒后重试。"
            case .forbidden: return "当前操作不可用，请检查发现设置或联系状态。"
            case .notFound, .gone: return "内容已不存在或尚未同步。"
            case .validation: return "请检查填写内容后再试。"
            case .decoding: return "暂时无法读取服务数据，请稍后重试。"
            default: break
            }
        }
        return error.localizedDescription
    }

    func modelBytes(asset: AssetItem) async throws -> Data {
        guard let assets else { throw MobileAPIError.invalidResponse("服务未配置") }
        let data = try await assets.data(for: asset)
        try Self.validateGLB(data, sha256: asset.sha256)
        return data
    }

    func goldenBytes(petID: String?) async throws -> Data {
        guard let client else { throw MobileAPIError.invalidResponse("服务未配置") }
        var path = "/public-assets/website-golden-master.glb"
        var digest: String? = "96efb8f20105d2280b332a13e926966c935c8e01e5ef5843be5183352283146b"
        if let petID, let homes {
            let result = try await homes.petHome(petId: petID)
            // MVP deliberately uses the website's static default golden retriever.
            path = result.manifest.defaultModel.url
            digest = result.manifest.defaultModel.sha256
        }
        guard path.hasPrefix("/public-assets/"), !path.contains("..") else {
            throw MobileAPIError.invalidResponse("默认形象地址不可用")
        }
        let data = try await client.download(.get(path, requiresAuth: false))
        try Self.validateGLB(data, sha256: digest)
        return data
    }

    static func validateGLB(_ data: Data, sha256: String?) throws {
        guard data.count >= 12, Array(data.prefix(4)) == [0x67, 0x6c, 0x54, 0x46] else {
            throw MobileAPIError.invalidResponse("模型格式不可用")
        }
        if let sha256, !sha256.isEmpty {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == sha256.lowercased() else {
                throw MobileAPIError.invalidResponse("模型下载不完整，请重试")
            }
        }
    }
}
