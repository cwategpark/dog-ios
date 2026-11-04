import Foundation
import XCTest
@testable import DogiosDataLayer

// MARK: - URLProtocol stub

/// 用 URLProtocol 拦截所有请求，测试不连真实网络。
final class StubURLProtocol: URLProtocol {
    struct StubResponse {
        var status: Int
        var headers: [String: String]
        var body: Data

        init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
            self.status = status
            self.headers = headers
            self.body = body
        }

        static func json(_ json: String,
                         status: Int = 200,
                         headers: [String: String] = ["Content-Type": "application/json"]) -> StubResponse {
            StubResponse(status: status, headers: headers, body: Data(json.utf8))
        }
    }

    typealias Handler = (URLRequest) throws -> StubResponse

    private static let lock = NSLock()
    private static var handler: Handler?
    private static var recorded: [URLRequest] = []

    static func setHandler(_ handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        recorded = []
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        handler = nil
        recorded = []
        lock.unlock()
    }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recorded.count
    }

    static func requests(path: String) -> [URLRequest] {
        requests.filter { $0.url?.path == path }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        do {
            let stub = try handler(request)
            let response = HTTPURLResponse(url: request.url ?? URL(string: "https://invalid.test")!,
                                           statusCode: stub.status,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: stub.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - 测试辅助

/// 线程安全计数器（stub handler 会在并发请求里被调用）。
final class TestCounter {
    private let lock = NSLock()
    private var value = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

func makeStubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: configuration)
}

/// 不读真实 Info.plist 的测试配置（https 合法地址）。
func makeTestConfig(baseURL: String = "https://api.example.test",
                    googleMapsAPIKey: String? = nil) throws -> AppConfig {
    var info: [String: Any] = [:]
    if let googleMapsAPIKey {
        info["GoogleMapsAPIKey"] = googleMapsAPIKey
    }
    return try AppConfig(settings: AppConfigSource(environment: ["DOGIOS_API_BASE_URL": baseURL],
                                                   infoDictionary: info))
}

/// 测试用 token 包。
func makeTokenBundle(access: String = "access-token-1",
                     refresh: String = "refresh-token-1") -> TokenBundle {
    TokenBundle(userId: "user-1",
                email: "a@b.com",
                accessToken: access,
                refreshToken: refresh)
}

/// 组装 client + 内存 token store。
func makeClient(accessToken: String? = "access-token-1",
                refreshToken: String? = "refresh-token-1",
                baseURL: String = "https://api.example.test") throws -> (MobileAPIClient, InMemoryTokenStore) {
    let store = InMemoryTokenStore()
    if let accessToken, let refreshToken {
        try store.save(makeTokenBundle(access: accessToken, refresh: refreshToken))
    } else if let accessToken {
        try store.save(TokenBundle(accessToken: accessToken, refreshToken: ""))
    }
    let config = try makeTestConfig(baseURL: baseURL)
    let client = MobileAPIClient(config: config, tokenStore: store, session: makeStubSession())
    return (client, store)
}

// MARK: - URLRequest 读取辅助

extension URLRequest {
    var httpBodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    var httpBodyJSON: [String: Any]? {
        guard let data = httpBodyData,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    var queryItems: [URLQueryItem] {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return []
        }
        return components.queryItems ?? []
    }

    func queryValue(_ name: String) -> String? {
        queryItems.first { $0.name == name }?.value
    }

    var authorizationHeader: String? {
        value(forHTTPHeaderField: "Authorization")
    }
}

// MARK: - 测试基类

class DataLayerTestCase: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }
}
