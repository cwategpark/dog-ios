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
    @Published var socialProfile: SocialProfile?
    @Published var socialAvatarData: Data?
    @Published var socialProfileError: String?
    @Published var socialProfileLoading = false
    private var profileOperation = UUID()
    private var socialOperation = UUID()
    let client: MobileAPIClient?
    let configurationError: String?
    var identity: IdentityService? { client.map(IdentityService.init) }
    var assets: AssetService? { client.map(AssetService.init) }
    var homes: PetHomeService? { client.map(PetHomeService.init) }
    var contacts: ContactService? { client.map(ContactService.init) }
    var messages: MessageService? { client.map(MessageService.init) }
    var discoveryService: DiscoveryService? { client.map(DiscoveryService.init) }
    var socialProfileService: SocialProfileService? { client.map(SocialProfileService.init) }

    /// The app shell must show the social-profile completion gate until the public nickname
    /// and an explicitly chosen avatar (default or upload) are saved. This is not a UI-only
    /// check: the server returns `profile_completed=false` for unverified/incomplete callers.
    var needsSocialProfile: Bool {
        me != nil && socialProfile?.profileCompleted != true
    }

    init(client suppliedClient: MobileAPIClient? = nil) {
        if let suppliedClient {
            client = suppliedClient
            configurationError = nil
            return
        }
        do {
            #if DEBUG && targetEnvironment(simulator)
            // Explicit simulator acceptance only: consume a real, short-lived server token
            // from a private fixture file. Keep the user's Keychain untouched. A path-only
            // override survives XCTest replacing the app data container before launch.
            if ProcessInfo.processInfo.arguments.contains("-ui-test-token-fixture") {
                let fixtureURL: URL
                if let path = ProcessInfo.processInfo.environment["DOGIOS_UI_TEST_TOKEN_FIXTURE_PATH"] {
                    let suppliedURL = URL(fileURLWithPath: path)
                    guard suppliedURL.lastPathComponent == ".pet-model-ui-token.private.json" else {
                        throw MobileAPIError.invalidResponse("测试登录文件无效")
                    }
                    fixtureURL = suppliedURL
                } else {
                    fixtureURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("pet-model-ui-token.json")
                }
                let bytes = try Data(contentsOf: fixtureURL)
                try FileManager.default.removeItem(at: fixtureURL)
                let bundle = try DogiosJSON.makeDecoder().decode(TokenBundle.self, from: bytes)
                client = MobileAPIClient(config: try AppConfig(), tokenStore: InMemoryTokenStore(bundle: bundle))
                configurationError = nil
                return
            }
            #endif
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
            socialProfile = nil
            socialAvatarData = nil
            socialProfileError = nil
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
        if changedAccount {
            sessionID = UUID()
            socialProfile = nil
            socialAvatarData = nil
            socialProfileError = nil
        }
    }

    // MARK: Social profile

    /// Load the server profile after login. It intentionally runs after `/me` rather than
    /// blocking token validation; the root shell gates social tabs on `needsSocialProfile`.
    func loadSocialProfile() async {
        guard let service = socialProfileService, me != nil, !socialProfileLoading else { return }
        let operation = UUID()
        socialOperation = operation
        socialProfileLoading = true
        socialProfileError = nil
        defer { if socialOperation == operation { socialProfileLoading = false } }
        do {
            let profile = try await service.get()
            guard socialOperation == operation, !Task.isCancelled else { return }
            socialProfile = profile
            await loadSocialAvatarIfNeeded(service: service, profile: profile, operation: operation)
        } catch {
            guard socialOperation == operation, !Task.isCancelled else { return }
            if !handleSessionError(error) {
                socialProfileError = friendly(error)
            }
        }
    }

    private func loadSocialAvatarIfNeeded(service: SocialProfileService,
                                          profile: SocialProfile,
                                          operation: UUID) async {
        guard profile.avatar.isUpload, profile.avatar.available else {
            socialAvatarData = nil
            return
        }
        do {
            let data = try await service.avatarData()
            guard socialOperation == operation, !Task.isCancelled else { return }
            socialAvatarData = data
        } catch {
            // Profile metadata is still usable; the avatar can be retried by the editor.
            if socialOperation == operation { socialAvatarData = nil }
        }
    }

    /// Save nickname/default-avatar selection. Uploaded avatar bytes are handled by
    /// `saveSocialAvatar` first; this method only patches textual/default choices.
    func saveSocialProfile(displayName: String?, defaultAvatarKey: String?) async throws {
        guard let service = socialProfileService else {
            throw MobileAPIError.invalidResponse("服务未配置")
        }
        let profile = try await service.update(displayName: displayName,
                                               defaultAvatarKey: defaultAvatarKey)
        socialProfile = profile
        socialProfileError = nil
        if profile.avatar.isDefault { socialAvatarData = nil }
        if profile.avatar.isUpload { socialAvatarData = try? await service.avatarData() }
    }

    /// Upload/replace the avatar and then patch the nickname when provided. Both calls are
    /// authenticated; the app never receives a storage path or public URL.
    func saveSocialAvatar(data: Data, contentType: String,
                          displayName: String? = nil) async throws {
        guard let service = socialProfileService else {
            throw MobileAPIError.invalidResponse("服务未配置")
        }
        var profile = try await service.uploadAvatar(data: data, contentType: contentType)
        socialAvatarData = data
        if let displayName, !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            profile = try await service.update(displayName: displayName, defaultAvatarKey: nil)
        }
        socialProfile = profile
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
        socialProfile = nil
        socialAvatarData = nil
        socialProfileError = nil
        socialProfileLoading = false
        socialOperation = UUID()
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

    /// Select the signed-in pet's saved model before the shared fallback. The manifest's
    /// private URL never enters JavaScript; only authenticated, validated bytes do.
    func petModel(petID: String?) async throws -> (data: Data, title: String) {
        guard let client, let homes, let assets else {
            throw MobileAPIError.invalidResponse("服务未配置")
        }
        let result = try await homes.petHome(petId: petID)
        switch result.model {
        case .personal(let model):
            guard let assetID = model.assetId, !assetID.isEmpty else {
                throw MobileAPIError.invalidResponse("宠物模型尚未同步完整，请重试")
            }
            let data = try await assets.download(assetId: assetID)
            try Self.validateGLB(data, sha256: model.sha256)
            let isReference = model.isReferenceModel == true || model.source == "confirmed-breed-reference"
            let title = isReference ? "品种参考模型" :
                (model.source == "photo-generated" ? "专属宠物模型" : "已保存的宠物模型")
            return (data, title)
        case .default(let model, _):
            let path = model.url
            guard (path.hasPrefix("/models/") || path.hasPrefix("/public-assets/")),
                  !path.contains(".."), !path.contains("://"),
                  !path.contains("?"), !path.contains("#") else {
                throw MobileAPIError.invalidResponse("默认形象地址不可用")
            }
            let data = try await client.download(.get(path, requiresAuth: false))
            try Self.validateGLB(data, sha256: model.sha256)
            return (data, "默认宠物形象")
        }
    }

    static func validateGLB(_ data: Data, sha256: String?) throws {
        guard data.count >= 12, Array(data.prefix(8)) == [0x67, 0x6c, 0x54, 0x46, 2, 0, 0, 0] else {
            throw MobileAPIError.invalidResponse("模型格式不可用")
        }
        let declaredLength = data[8..<12].enumerated().reduce(UInt32(0)) {
            $0 | (UInt32($1.element) << UInt32($1.offset * 8))
        }
        guard UInt64(declaredLength) == UInt64(data.count) else {
            throw MobileAPIError.invalidResponse("模型下载不完整，请重试")
        }
        if let sha256, !sha256.isEmpty {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == sha256.lowercased() else {
                throw MobileAPIError.invalidResponse("模型下载不完整，请重试")
            }
        }
    }
}
