import Foundation

/// 数据层统一错误。
///
/// HTTP 状态码映射语义错误（契约 §1）：401 unauthorized / 403 forbidden / 404 notFound /
/// 409 conflict / 410 gone / 422 validation / 429 rateLimited / 503 unavailable / 5xx server；
/// 网络错误单独成类，不与 HTTP 错误混用。
///
/// 注意：类型名带 `Mobile` 前缀，避免与既有演示 UI 的 `PawlyDemo/Core/APIError.swift`
/// 中旧的 `APIError` 重名（两者同属 App target）。
public struct MobileAPIError: Error, Equatable, LocalizedError, CustomStringConvertible {
    public enum Kind: Equatable, Sendable {
        case unauthorized
        case forbidden
        case notFound
        case conflict
        case gone
        case validation
        case rateLimited
        case unavailable
        case server
        /// 其它 4xx。
        case client
        /// 网络层失败（无 HTTP 响应）。
        case network
        /// 响应 JSON 无法解码。
        case decoding
        /// 响应非法（URL 构造失败、非 HTTP 响应等）。
        case invalidResponse
        /// 调用方取消。
        case cancelled
    }

    public let kind: Kind
    public let status: Int?
    public let code: String?
    public let message: String
    public let retryable: Bool
    /// 来自 429/503 的 `Retry-After`（秒）。
    public let retryAfter: TimeInterval?
    public let underlying: String?
    /// Account session that produced this error; late failures cannot clear another login.
    public let sessionGeneration: UUID?

    public init(kind: Kind,
                status: Int? = nil,
                code: String? = nil,
                message: String = "",
                retryable: Bool = false,
                retryAfter: TimeInterval? = nil,
                underlying: String? = nil,
                sessionGeneration: UUID? = nil) {
        self.kind = kind
        self.status = status
        self.code = code
        self.message = message
        self.retryable = retryable
        self.retryAfter = retryAfter
        self.underlying = underlying
        self.sessionGeneration = sessionGeneration
    }

    func scoped(to generation: UUID) -> MobileAPIError {
        MobileAPIError(kind: kind, status: status, code: code, message: message,
                       retryable: retryable, retryAfter: retryAfter, underlying: underlying,
                       sessionGeneration: generation)
    }

    public var isUnauthorized: Bool { kind == .unauthorized }
    public var isForbidden: Bool { kind == .forbidden }
    public var isNotFound: Bool { kind == .notFound }
    public var isConflict: Bool { kind == .conflict }
    public var isValidation: Bool { kind == .validation }
    public var isRateLimited: Bool { kind == .rateLimited }
    public var isUnavailable: Bool { kind == .unavailable }
    public var isNetwork: Bool { kind == .network }

    public var errorDescription: String? { message.isEmpty ? code : message }
    public var description: String {
        var parts: [String] = [String(describing: kind)]
        if let status { parts.append("status=\(status)") }
        if let code { parts.append("code=\(code)") }
        if !message.isEmpty { parts.append(message) }
        return "MobileAPIError(\(parts.joined(separator: ", ")))"
    }

    // MARK: - 构造

    /// 由 HTTP 响应构造语义错误。`{"detail": "<code>"}` 是契约错误体。
    public static func from(status: Int,
                            data: Data? = nil,
                            headers: [String: String]? = nil) -> MobileAPIError {
        let parsed = parseErrorBody(data)
        let kind = kind(for: status)
        let retryAfter = headers.flatMap { headerValue("Retry-After", in: $0) }
            .flatMap { TimeInterval($0) }
            ?? parsed.retryAfter
        let retryable = kind == .network || kind == .rateLimited || kind == .unavailable || kind == .server
        return MobileAPIError(kind: kind,
                              status: status,
                              code: parsed.code,
                              message: parsed.message,
                              retryable: retryable,
                              retryAfter: retryAfter,
                              underlying: nil)
    }

    public static func kind(for status: Int) -> Kind {
        switch status {
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 409: return .conflict
        case 410: return .gone
        case 422: return .validation
        case 429: return .rateLimited
        case 503: return .unavailable
        case 500...599: return .server
        default: return .client
        }
    }

    public static func network(_ error: Error) -> MobileAPIError {
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return .cancelled()
        }
        return MobileAPIError(kind: .network,
                              code: "NETWORK_ERROR",
                              message: error.localizedDescription,
                              retryable: true,
                              underlying: String(describing: error))
    }

    public static func decoding(_ error: Error) -> MobileAPIError {
        MobileAPIError(kind: .decoding,
                       code: "DECODING_ERROR",
                       message: error.localizedDescription,
                       retryable: false,
                       underlying: String(describing: error))
    }

    public static func invalidResponse(_ message: String) -> MobileAPIError {
        MobileAPIError(kind: .invalidResponse, code: "INVALID_RESPONSE", message: message)
    }

    public static func cancelled() -> MobileAPIError {
        MobileAPIError(kind: .cancelled, code: "CANCELLED", message: "请求已取消")
    }

    /// 401 且无法通过 refresh 恢复（无 refresh token / refresh 被拒）。
    public static func unauthorized(_ message: String = "登录状态已失效，请重新登录") -> MobileAPIError {
        MobileAPIError(kind: .unauthorized, status: 401, code: "UNAUTHENTICATED", message: message)
    }

    // MARK: - 内部解析

    private struct ParsedBody {
        var code: String?
        var message: String
        var retryAfter: TimeInterval?
    }

    private static func parseErrorBody(_ data: Data?) -> ParsedBody {
        guard let data, !data.isEmpty else {
            return ParsedBody(code: nil, message: "服务端返回错误", retryAfter: nil)
        }
        // 契约格式：{"detail": "<code>"}；兼容 detail 为对象或 message 字段。
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = object["detail"] as? String {
                return ParsedBody(code: detail, message: detail, retryAfter: nil)
            }
            if let detail = object["detail"] as? [String: Any] {
                let code = detail["code"] as? String
                let message = detail["message"] as? String ?? code
                return ParsedBody(code: code, message: message ?? "服务端返回错误", retryAfter: nil)
            }
            if let code = object["code"] as? String {
                return ParsedBody(code: code, message: object["message"] as? String ?? code, retryAfter: nil)
            }
            if let message = object["message"] as? String {
                return ParsedBody(code: nil, message: message, retryAfter: nil)
            }
        }
        let text = String(data: data, encoding: .utf8) ?? "服务端返回错误"
        return ParsedBody(code: nil, message: text, retryAfter: nil)
    }

    private static func headerValue(_ name: String, in headers: [String: String]) -> String? {
        if let exact = headers[name] { return exact }
        return headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
