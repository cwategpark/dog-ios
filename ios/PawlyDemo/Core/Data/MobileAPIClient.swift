import Foundation

// MARK: - 请求描述

/// 一次 API 调用描述。`path` 以 `/mobile/v1` 开头，拼在 `AppConfig.baseURL` 之后。
public struct APIRequest {
    public var method: String
    public var path: String
    public var query: [URLQueryItem]
    public var body: Data?
    public var headers: [String: String]
    /// 为 true 时自动加 `Authorization: Bearer <access_token>`（默认 true）。
    public var requiresAuth: Bool
    public var cachePolicy: URLRequest.CachePolicy

    public init(method: String = "GET",
                path: String,
                query: [URLQueryItem] = [],
                body: Data? = nil,
                headers: [String: String] = [:],
                requiresAuth: Bool = true,
                cachePolicy: URLRequest.CachePolicy = .reloadIgnoringLocalCacheData) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.headers = headers
        self.requiresAuth = requiresAuth
        self.cachePolicy = cachePolicy
    }

    public static func get(_ path: String,
                           query: [URLQueryItem] = [],
                           requiresAuth: Bool = true) -> APIRequest {
        APIRequest(method: "GET", path: path, query: query, requiresAuth: requiresAuth)
    }

    public static func post(_ path: String,
                            body: Data? = nil,
                            requiresAuth: Bool = true) -> APIRequest {
        APIRequest(method: "POST", path: path, body: body, requiresAuth: requiresAuth)
    }

    public static func delete(_ path: String,
                              requiresAuth: Bool = true) -> APIRequest {
        APIRequest(method: "DELETE", path: path, requiresAuth: requiresAuth)
    }
}

/// 无响应体（204）的占位 Decodable。
public struct EmptyBody: Decodable, Equatable, Sendable {
    public init() {}
}

// MARK: - MobileAPIClient

/// 移动端数据层 HTTP 客户端。
///
/// - async/await `URLSession`，JSON snake_case。
/// - 需要认证的请求自动加 `Authorization: Bearer`。
/// - 401：用 refresh token **单飞（single-flight）** 刷新，成功后原请求重试一次；
///   refresh 失败则清空 token 并抛 `MobileAPIError.unauthorized`。
/// - 可通过 `session` 注入 `URLProtocol` stub，测试不连真实网络。
public final class MobileAPIClient: @unchecked Sendable {
    public let config: AppConfig
    public let tokenStore: TokenStoring
    public let session: URLSession
    public let decoder: JSONDecoder
    public let encoder: JSONEncoder

    // Credentials and refresh commits share one lock. A generation identifies an
    // account session, while token rotations keep the same generation.
    private let stateLock = NSLock()
    private var generation = UUID()
    private struct RefreshFlight {
        let id: UUID
        let generation: UUID
        let task: Task<TokenBundle, Error>
    }
    private var refreshFlight: RefreshFlight?

    public init(config: AppConfig,
                tokenStore: TokenStoring? = nil,
                session: URLSession = .dogiosDefault,
                decoder: JSONDecoder = DogiosJSON.makeDecoder(),
                encoder: JSONEncoder = DogiosJSON.makeEncoder()) {
        self.config = config
        self.tokenStore = tokenStore ?? KeychainTokenStore()
        self.session = session
        self.decoder = decoder
        self.encoder = encoder
    }

    // MARK: Token

    private func withState<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    public var sessionGeneration: UUID { withState { generation } }
    public var accessToken: String? { sessionSnapshot().token?.accessToken }
    public var hasSession: Bool { sessionSnapshot().token != nil }
    public var currentToken: TokenBundle? { sessionSnapshot().token }

    private func sessionSnapshot() -> (generation: UUID, token: TokenBundle?) {
        withState { (generation, tokenStore.load()) }
    }

    /// Explicit login starts a new session, invalidating work from the old account.
    public func store(_ bundle: TokenBundle) throws {
        try replaceSession(bundle, expectedGeneration: nil)
    }

    /// An OTP response may only install credentials in the session that started it.
    public func store(_ bundle: TokenBundle, ifGeneration expected: UUID) throws {
        try replaceSession(bundle, expectedGeneration: expected)
    }

    private func replaceSession(_ bundle: TokenBundle, expectedGeneration: UUID?) throws {
        let oldTask: Task<TokenBundle, Error>? = try withState {
            if let expectedGeneration, generation != expectedGeneration {
                throw MobileAPIError.cancelled()
            }
            try tokenStore.save(bundle)
            generation = UUID()
            let old = refreshFlight?.task
            refreshFlight = nil
            return old
        }
        oldTask?.cancel()
    }

    public func clearSession() { _ = takeSessionForLogout() }

    /// Conditional invalidation prevents a late 401 from signing out a new account.
    @discardableResult
    public func clearSession(ifGeneration expected: UUID) -> Bool {
        invalidateSession(expected: expected).changed
    }

    /// Synchronously removes credentials before any logout network request begins.
    /// The returned bundle can only be used to revoke that captured old session.
    public func takeSessionForLogout() -> TokenBundle? {
        invalidateSession(expected: nil).token
    }

    private func invalidateSession(expected: UUID?) -> (changed: Bool, token: TokenBundle?) {
        let result: (Bool, TokenBundle?, Task<TokenBundle, Error>?) = withState {
            if let expected, generation != expected { return (false, nil, nil) }
            let token = tokenStore.load()
            generation = UUID()
            tokenStore.clear()
            let old = refreshFlight?.task
            refreshFlight = nil
            return (true, token, old)
        }
        result.2?.cancel()
        return (result.0, result.1)
    }

    public func refreshSession() async throws -> TokenBundle {
        let snapshot = sessionSnapshot()
        return try await refreshTokens(generation: snapshot.generation, rejectedAccess: nil)
    }

    private func assertCurrent(_ expected: UUID) throws {
        guard withState({ generation == expected }), !Task.isCancelled else {
            throw MobileAPIError.cancelled()
        }
    }

    /// Installs one refresh per generation. A late 401 using an already-rotated
    /// access token reuses current credentials instead of rotating a second time.
    private func refreshTokens(generation expected: UUID, rejectedAccess: String?) async throws -> TokenBundle {
        let selection: (TokenBundle?, RefreshFlight?) = try withState {
            guard generation == expected else { throw MobileAPIError.cancelled() }
            guard let current = tokenStore.load(), !current.refreshToken.isEmpty else {
                throw MobileAPIError.unauthorized().scoped(to: expected)
            }
            if let rejectedAccess, current.accessToken != rejectedAccess { return (current, nil) }
            if let flight = refreshFlight, flight.generation == expected { return (nil, flight) }
            let id = UUID()
            let flight = RefreshFlight(id: id, generation: expected, task: Task { [self] in
                do {
                    let bundle = try await performRefresh(refreshToken: current.refreshToken)
                    try withState {
                        guard generation == expected,
                              tokenStore.load()?.refreshToken == current.refreshToken else {
                            throw MobileAPIError.cancelled()
                        }
                        try tokenStore.save(bundle)
                    }
                    return bundle
                } catch {
                    // Only this generation may lose credentials. A response from
                    // an old refresh can neither overwrite nor clear a new login.
                    let isCurrent = withState {
                        guard generation == expected else { return false }
                        if tokenStore.load()?.refreshToken == current.refreshToken { tokenStore.clear() }
                        return true
                    }
                    guard isCurrent else { throw MobileAPIError.cancelled() }
                    if let api = error as? MobileAPIError, api.kind == .cancelled { throw api }
                    throw MobileAPIError.unauthorized().scoped(to: expected)
                }
            })
            refreshFlight = flight
            return (nil, flight)
        }
        if let token = selection.0 { return token }
        guard let flight = selection.1 else { throw MobileAPIError.cancelled() }
        defer {
            withState {
                if refreshFlight?.id == flight.id { refreshFlight = nil }
            }
        }
        let bundle = try await flight.task.value
        try assertCurrent(expected)
        return bundle
    }

    private func performRefresh(refreshToken: String) async throws -> TokenBundle {
        struct RefreshRequest: Encodable { let refreshToken: String }
        let body = try encoder.encode(RefreshRequest(refreshToken: refreshToken))
        let request = APIRequest(method: "POST",
                                 path: "/mobile/v1/auth/refresh",
                                 body: body,
                                 requiresAuth: false)
        let (data, response) = try await rawPerform(request)
        guard (200..<300).contains(response.statusCode) else {
            throw MobileAPIError.from(status: response.statusCode,
                                      data: data,
                                      headers: response.dogiosHeaders)
        }
        do {
            return try decoder.decode(TokenBundle.self, from: data)
        } catch {
            throw MobileAPIError.decoding(error)
        }
    }

    // MARK: 发送

    public func send<Response: Decodable>(_ request: APIRequest,
                                          as type: Response.Type = Response.self) async throws -> Response {
        let (data, _) = try await perform(request)
        if data.isEmpty, let empty = EmptyBody() as? Response {
            return empty
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw MobileAPIError.decoding(error)
        }
    }

    public func sendNoContent(_ request: APIRequest) async throws {
        _ = try await perform(request)
    }

    /// 需认证的字节下载（私有资产）：返回 Data 而不是把私有 URL 当公开链接。
    public func download(_ request: APIRequest) async throws -> Data {
        let (data, _) = try await perform(request)
        return data
    }

    /// 请求体编码（UTF-8 JSON，snake_case）。
    public func encodeBody<Body: Encodable>(_ body: Body) throws -> Data {
        do {
            return try encoder.encode(body)
        } catch {
            throw MobileAPIError.decoding(error)
        }
    }

    // MARK: 内部传输

    /// 构造完整 URL：`baseURL` + `path` + query。
    public func makeURL(_ request: APIRequest) throws -> URL {
        let base = config.baseURL.absoluteString
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        let suffix = request.path.hasPrefix("/") ? request.path : "/" + request.path
        guard var components = URLComponents(string: root + suffix) else {
            throw MobileAPIError.invalidResponse("URL 构造失败：\(root + suffix)")
        }
        if !request.query.isEmpty {
            components.queryItems = request.query
        }
        guard let url = components.url else {
            throw MobileAPIError.invalidResponse("URL 构造失败：\(root + suffix)")
        }
        return url
    }

    /// 发送并在 401 时单飞刷新后重试一次。
    private func perform(_ request: APIRequest) async throws -> (Data, HTTPURLResponse) {
        let original = sessionSnapshot()
        var token = request.requiresAuth ? original.token?.accessToken : nil
        var didRetry = false
        while true {
            if request.requiresAuth { try assertCurrent(original.generation) }
            do {
                let (data, response) = try await rawPerform(request, accessToken: token)
                if request.requiresAuth { try assertCurrent(original.generation) }
                if response.statusCode == 401, request.requiresAuth, !didRetry {
                    token = try await refreshTokens(generation: original.generation,
                                                    rejectedAccess: token).accessToken
                    didRetry = true
                    continue
                }
                guard (200..<300).contains(response.statusCode) else {
                    let error = MobileAPIError.from(status: response.statusCode, data: data,
                                                    headers: response.dogiosHeaders)
                    throw request.requiresAuth ? error.scoped(to: original.generation) : error
                }
                return (data, response)
            } catch {
                if request.requiresAuth {
                    try assertCurrent(original.generation)
                    if let api = error as? MobileAPIError { throw api.scoped(to: original.generation) }
                }
                throw error
            }
        }
    }

    private func rawPerform(_ request: APIRequest, accessToken: String? = nil) async throws -> (Data, HTTPURLResponse) {
        let url = try makeURL(request)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.cachePolicy = request.cachePolicy
        urlRequest.timeoutInterval = session.configuration.timeoutIntervalForRequest
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if request.body != nil {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        if request.requiresAuth,
           let token = accessToken,
           !token.isEmpty {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw MobileAPIError.invalidResponse("非 HTTP 响应")
            }
            return (data, http)
        } catch let error as MobileAPIError {
            throw error
        } catch {
            throw MobileAPIError.network(error)
        }
    }
}

// MARK: - URLSession 默认配置

public extension URLSession {
    /// 数据层默认 session：无本地缓存（私有资产不落缓存）、带超时。
    static var dogiosDefault: URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }
}

extension HTTPURLResponse {
    /// 归一化的响应头（小写不敏感查询由错误类型负责）。
    var dogiosHeaders: [String: String] {
        allHeaderFields.reduce(into: [String: String]()) { result, pair in
            result[String(describing: pair.key)] = String(describing: pair.value)
        }
    }
}
