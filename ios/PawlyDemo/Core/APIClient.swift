import Foundation

struct APIResult<T> {
    let value: T
    let status: Int
    let etag: String?
    let headers: [String: String]
}

struct EmptyResponse: Decodable {}

struct UploadCompleteResponse: Decodable {
    let asset: Asset
    let state: String
}

struct HealthResponse: Decodable {
    let ok: Bool
    let version: String?
    let seeded: Bool?
}

private struct Idempotency {
    let key: String
}

/// Thin async/await HTTP client for the Pawly demo API.
@MainActor
final class APIClient {
    var baseURL: URL
    var token: String?
    var language: String = "zh-CN"
    var onUnauthorized: (() -> Void)?

    private let session: URLSession
    private let decoder: JSONDecoder

    init(baseURL: URL = URL(string: "http://127.0.0.1:8788")!) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    // MARK: - Core transport

    private func makeURL(path: String, query: [URLQueryItem]) -> URL? {
        let base = baseURL.absoluteString.hasSuffix("/")
            ? String(baseURL.absoluteString.dropLast())
            : baseURL.absoluteString
        let full = base + (path.hasPrefix("/") ? path : "/" + path)
        guard var components = URLComponents(string: full) else { return nil }
        if !query.isEmpty { components.queryItems = query }
        return components.url
    }

    private func perform<T: Decodable>(method: String,
                                       path: String,
                                       query: [URLQueryItem] = [],
                                       jsonBody: [String: Any]? = nil,
                                       dataBody: Data? = nil,
                                       headers: [String: String] = [:],
                                       authenticated: Bool = true) async throws -> APIResult<T> {
        guard let url = makeURL(path: path, query: query) else {
            throw APIError.unexpected("Invalid URL for \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(language, forHTTPHeaderField: "X-Pawly-Language")
        if authenticated, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let dataBody {
            request.httpBody = dataBody
        } else if let jsonBody {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.unexpected("Missing HTTP response")
        }
        if http.statusCode == 401 {
            onUnauthorized?()
        }
        guard (200...299).contains(http.statusCode) else {
            throw Self.makeError(status: http.statusCode, data: data, decoder: decoder)
        }

        var resultHeaders: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                resultHeaders[key] = value
            }
        }
        let etag = http.value(forHTTPHeaderField: "ETag")

        let value: T
        if T.self is EmptyResponse.Type {
            value = EmptyResponse() as! T
        } else if data.isEmpty {
            throw APIError.decoding(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Empty response body")))
        } else {
            do {
                value = try decoder.decode(T.self, from: data)
            } catch {
                throw APIError.decoding(error)
            }
        }
        return APIResult(value: value, status: http.statusCode, etag: etag, headers: resultHeaders)
    }

    private static func makeError(status: Int, data: Data, decoder: JSONDecoder) -> APIError {
        let body = try? decoder.decode(ErrorBody.self, from: data)
        return APIError(kind: .http,
                        status: status,
                        code: body?.code ?? "HTTP_\(status)",
                        message: body?.message ?? "HTTP \(status)",
                        requestId: body?.requestId,
                        retryable: body?.retryable ?? false,
                        fieldErrors: body?.fieldErrors ?? [],
                        underlying: nil)
    }

    // MARK: - Auth

    func exchangeDemoCustomer() async throws -> APIResult<AuthSession> {
        try await perform(method: "POST", path: "/v1/auth/exchange",
                          jsonBody: ["customer_access_token": "demo-customer-token-2026"],
                          authenticated: false)
    }

    func guestLogin(language: String) async throws -> APIResult<AuthSession> {
        try await perform(method: "POST", path: "/v1/auth/guest",
                          jsonBody: ["language_code": language],
                          authenticated: false)
    }

    func claim(code: String) async throws -> APIResult<AuthSession> {
        try await perform(method: "POST", path: "/v1/auth/claim",
                          jsonBody: ["claim_code": code])
    }

    func logout() async throws {
        _ = try await perform(method: "POST", path: "/v1/auth/logout") as APIResult<EmptyResponse>
    }

    func me() async throws -> APIResult<MeResponse> {
        try await perform(method: "GET", path: "/v1/me")
    }

    // MARK: - Profile / preferences / consents

    func profile() async throws -> APIResult<Profile> {
        try await perform(method: "GET", path: "/v1/me/profile")
    }

    func updateProfile(email: String?, fullName: String?, etag: String?) async throws -> APIResult<Profile> {
        var body: [String: Any] = [:]
        if let email { body["contact_email"] = email }
        if let fullName { body["full_name"] = fullName }
        var headers: [String: String] = [:]
        if let etag { headers["If-Match"] = etag }
        return try await perform(method: "PATCH", path: "/v1/me/profile", jsonBody: body, headers: headers)
    }

    func preferences() async throws -> APIResult<UserPreferences> {
        try await perform(method: "GET", path: "/v1/me/preferences")
    }

    func updatePreferences(locale: String?, theme: String?, etag: String?) async throws -> APIResult<UserPreferences> {
        var body: [String: Any] = [:]
        if let locale { body["locale"] = locale }
        if let theme { body["theme_preference"] = theme }
        var headers: [String: String] = [:]
        if let etag { headers["If-Match"] = etag }
        return try await perform(method: "PATCH", path: "/v1/me/preferences", jsonBody: body, headers: headers)
    }

    func consents() async throws -> APIResult<ConsentList> {
        try await perform(method: "GET", path: "/v1/me/consents")
    }

    func createConsents(_ items: [[String: Any]]) async throws -> APIResult<ConsentList> {
        try await perform(method: "POST", path: "/v1/consents",
                          jsonBody: ["items": items],
                          headers: ["Idempotency-Key": UUID().uuidString])
    }

    // MARK: - Pets

    func pets(limit: Int = 50) async throws -> APIResult<PetList> {
        try await perform(method: "GET", path: "/v1/pets",
                          query: [URLQueryItem(name: "limit", value: String(limit))])
    }

    func createPet(name: String, species: String, dogSize: String?, ageMonths: Int?) async throws -> APIResult<Pet> {
        var body: [String: Any] = ["name": name, "species": species]
        body["dog_size"] = dogSize ?? NSNull()
        body["reported_age_months"] = ageMonths ?? NSNull()
        if ageMonths != nil {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            body["age_reported_at"] = formatter.string(from: Date())
        }
        return try await perform(method: "POST", path: "/v1/pets", jsonBody: body)
    }

    // MARK: - Catalog

    func products(query: [URLQueryItem]) async throws -> APIResult<ProductList> {
        try await perform(method: "GET", path: "/v1/products", query: query)
    }

    func product(productGID: String) async throws -> APIResult<Product> {
        try await perform(method: "GET", path: "/v1/products/\(Self.pathEncode(productGID))")
    }

    func recommendation(id: String) async throws -> APIResult<Recommendation> {
        try await perform(method: "GET", path: "/v1/recommendations/\(Self.pathEncode(id))")
    }

    // MARK: - Cart

    func resolveCart(country: String = "US") async throws -> APIResult<Cart> {
        try await perform(method: "POST", path: "/v1/carts/resolve",
                          jsonBody: ["country_code": country, "language_code": language],
                          headers: ["Idempotency-Key": UUID().uuidString])
    }

    func cart(id: String) async throws -> APIResult<Cart> {
        try await perform(method: "GET", path: "/v1/carts/\(Self.pathEncode(id))")
    }

    func addLine(cartID: String,
                 variantGID: String,
                 quantity: Int,
                 customizationID: String?,
                 petID: String?) async throws -> APIResult<Cart> {
        var body: [String: Any] = ["variant_gid": variantGID, "quantity": quantity]
        if let customizationID { body["customization_id"] = customizationID }
        if let petID { body["pet_id"] = petID }
        return try await perform(method: "POST", path: "/v1/carts/\(Self.pathEncode(cartID))/lines",
                                 jsonBody: body,
                                 headers: ["Idempotency-Key": UUID().uuidString])
    }

    func deleteLine(cartID: String, lineID: String) async throws {
        _ = try await perform(method: "DELETE",
                              path: "/v1/carts/\(Self.pathEncode(cartID))/lines/\(Self.pathEncode(lineID))") as APIResult<EmptyResponse>
    }

    func checkout(cartID: String) async throws -> APIResult<Checkout> {
        try await perform(method: "POST", path: "/v1/carts/\(Self.pathEncode(cartID))/checkout")
    }

    func checkoutSession(token: String) async throws -> APIResult<CheckoutSession> {
        try await perform(method: "GET", path: "/v1/checkout-sessions/\(Self.pathEncode(token))", authenticated: false)
    }

    func confirmCheckout(token: String) async throws -> APIResult<Order> {
        try await perform(method: "POST", path: "/v1/checkout-sessions/\(Self.pathEncode(token))/confirm", authenticated: false)
    }

    func order(id: String) async throws -> APIResult<Order> {
        try await perform(method: "GET", path: "/v1/orders/\(Self.pathEncode(id))")
    }

    // MARK: - Uploads / assets

    func createUpload(petID: String, mimeType: String, byteSize: Int, sha256: String) async throws -> APIResult<UploadTicket> {
        try await perform(method: "POST", path: "/v1/uploads",
                          jsonBody: ["pet_id": petID,
                                     "purpose": "pet_photo",
                                     "mime_type": mimeType,
                                     "byte_size": byteSize,
                                     "sha256": sha256],
                          headers: ["Idempotency-Key": UUID().uuidString])
    }

    func putUpload(ticket: UploadTicket, data: Data) async throws {
        guard let url = URL(string: ticket.url) else {
            throw APIError.unexpected("Invalid upload ticket URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = ticket.method.isEmpty ? "PUT" : ticket.method
        for (key, value) in ticket.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = data
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.unexpected("Missing upload response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw Self.makeError(status: http.statusCode, data: body, decoder: decoder)
        }
    }

    func completeUpload(uploadID: String) async throws -> APIResult<UploadCompleteResponse> {
        try await perform(method: "POST", path: "/v1/uploads/\(Self.pathEncode(uploadID))/complete")
    }

    func assetAccess(assetID: String) async throws -> APIResult<AssetAccess> {
        try await perform(method: "POST", path: "/v1/assets/\(Self.pathEncode(assetID))/access")
    }

    // MARK: - Generation

    func templates() async throws -> APIResult<GenerationTemplateList> {
        try await perform(method: "GET", path: "/v1/config/templates")
    }

    func createGenerationJob(petID: String,
                             sourceAssetIDs: [String],
                             method: String,
                             templateVersionID: String?,
                             consentEventIDs: [String]) async throws -> APIResult<GenerationJob> {
        var body: [String: Any] = ["pet_id": petID,
                                   "source_asset_ids": sourceAssetIDs,
                                   "generation_method": method,
                                   "consent_event_ids": consentEventIDs]
        if let templateVersionID { body["template_version_id"] = templateVersionID }
        return try await perform(method: "POST", path: "/v1/generation-jobs",
                                 jsonBody: body,
                                 headers: ["Idempotency-Key": UUID().uuidString])
    }

    func generationJobs(limit: Int = 20) async throws -> APIResult<GenerationJobList> {
        try await perform(method: "GET", path: "/v1/generation-jobs",
                          query: [URLQueryItem(name: "limit", value: String(limit))])
    }

    func generationJob(id: String) async throws -> APIResult<GenerationJob> {
        try await perform(method: "GET", path: "/v1/generation-jobs/\(Self.pathEncode(id))")
    }

    func cancelGenerationJob(id: String) async throws -> APIResult<GenerationJob> {
        try await perform(method: "POST", path: "/v1/generation-jobs/\(Self.pathEncode(id))/cancel",
                          headers: ["Idempotency-Key": UUID().uuidString])
    }

    // MARK: - Appearance / privacy / health

    func appearance(channel: String = "ios") async throws -> APIResult<AppearancePayload> {
        try await perform(method: "GET", path: "/v1/config/appearance",
                          query: [URLQueryItem(name: "channel", value: channel)],
                          authenticated: false)
    }

    func createPrivacyRequest(kind: String) async throws -> APIResult<PrivacyRequest> {
        try await perform(method: "POST", path: "/v1/privacy/requests",
                          jsonBody: ["kind": kind],
                          headers: ["Idempotency-Key": UUID().uuidString])
    }

    func privacyRequest(id: String) async throws -> APIResult<PrivacyRequest> {
        try await perform(method: "GET", path: "/v1/privacy/requests/\(Self.pathEncode(id))")
    }

    func healthz() async throws -> APIResult<HealthResponse> {
        try await perform(method: "GET", path: "/healthz", authenticated: false)
    }

    // MARK: - Helpers

    static func pathEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Resolve a possibly-relative media URL against the API base URL.
    func absoluteURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        if let url = URL(string: raw), url.scheme != nil { return url }
        if raw.hasPrefix("/") {
            return URL(string: raw, relativeTo: baseURL)?.absoluteURL
        }
        return nil
    }
}
