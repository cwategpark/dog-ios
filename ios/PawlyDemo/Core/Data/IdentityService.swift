import Foundation

/// 身份（OTP 邮箱登录 / 刷新 / 登出）。
///
/// 对应契约 §2：`/mobile/v1/auth/email/start`、`/auth/email/verify`、
/// `/auth/refresh`、`/auth/logout`。`user_id` 只是业务归属，不是登录凭据；
/// 登录使用短 access token + 轮换 refresh token，存 `TokenStoring`。
public final class IdentityService: @unchecked Sendable {
    private let client: MobileAPIClient

    public init(client: MobileAPIClient) {
        self.client = client
    }

    public var isAuthenticated: Bool {
        client.hasSession
    }

    public var currentToken: TokenBundle? {
        client.currentToken
    }

    /// POST `/mobile/v1/auth/email/start`。
    /// - Parameters:
    ///   - email: 规范化（trim + lowercase）后提交。
    ///   - purpose: `.login` 只登录；`.claim` 显式认领游客会话，需带 claimLink。
    public func startEmailVerification(email: String,
                                       purpose: EmailPurpose = .login,
                                       claimLink: String? = nil) async throws -> EmailChallenge {
        struct EmailStartRequest: Encodable {
            let email: String
            let purpose: String
            let claimLink: String?
        }
        let normalized = IdentityService.normalizedEmail(email)
        let payload = EmailStartRequest(email: normalized,
                                        purpose: purpose.rawValue,
                                        claimLink: claimLink)
        let body = try client.encodeBody(payload)
        return try await client.send(.post("/mobile/v1/auth/email/start",
                                           body: body,
                                           requiresAuth: false),
                                     as: EmailChallenge.self)
    }

    /// POST `/mobile/v1/auth/email/verify`：成功后把 token 包写入 `TokenStoring`。
    public func verifyEmail(challengeId: String, code: String) async throws -> TokenBundle {
        let generation = client.sessionGeneration
        struct VerifyRequest: Encodable {
            let challengeId: String
            let code: String
        }
        let body = try client.encodeBody(VerifyRequest(challengeId: challengeId,
                                                       code: code.trimmingCharacters(in: .whitespacesAndNewlines)))
        let bundle = try await client.send(.post("/mobile/v1/auth/email/verify",
                                                 body: body,
                                                 requiresAuth: false),
                                           as: TokenBundle.self)
        try client.store(bundle, ifGeneration: generation)
        return bundle
    }

    /// 主动刷新（内部也是 single-flight）。
    public func refresh() async throws -> TokenBundle {
        try await client.refreshSession()
    }

    /// POST `/mobile/v1/auth/logout`：吊销会话，无论服务端结果如何都清本地 token。
    public func logout() async throws {
        let captured = client.takeSessionForLogout()
        try await revokeSession(captured)
    }

    /// Revokes captured credentials without reading, refreshing or clearing the
    /// current session. Safe even when another account logs in during this call.
    public func revokeSession(_ captured: TokenBundle?) async throws {
        guard let captured, !captured.refreshToken.isEmpty else { return }
        struct LogoutRequest: Encodable { let refreshToken: String }
        let body = try client.encodeBody(LogoutRequest(refreshToken: captured.refreshToken))
        var request = APIRequest.post("/mobile/v1/auth/logout", body: body, requiresAuth: false)
        if !captured.accessToken.isEmpty {
            request.headers["Authorization"] = "Bearer \(captured.accessToken)"
        }
        try await client.sendNoContent(request)
    }

    /// GET `/mobile/v1/me`。
    public func me() async throws -> MobileMeResponse {
        try await client.send(.get("/mobile/v1/me"), as: MobileMeResponse.self)
    }

    /// 契约 §1：trim + lowercase，不做 Gmail 点号/`+tag` 归一。
    public static func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
