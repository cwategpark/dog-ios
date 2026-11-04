import Foundation

// MARK: - 配置错误

/// 数据层配置错误。生产环境只接受 https；明文 http 仅允许本机回环地址。
public enum AppConfigError: Error, Equatable, LocalizedError, CustomStringConvertible {
    /// 非 localhost 地址使用了 http。
    case insecureBaseURL(String)
    /// 不是合法的绝对 URL（缺 scheme/host、或构建设置未展开）。
    case invalidBaseURL(String)

    public var errorDescription: String? {
        switch self {
        case .insecureBaseURL(let value):
            return "baseURL 必须使用 https（仅 localhost 允许明文 http）：\(value)"
        case .invalidBaseURL(let value):
            return "baseURL 不是合法的绝对 URL：\(value)"
        }
    }

    public var description: String { errorDescription ?? "AppConfigError" }
}

// MARK: - 配置来源（可注入，测试不读真实 Info.plist）

/// 配置读取来源。生产使用 `.process`；测试注入 environment / infoDictionary。
public struct AppConfigSource {
    public var environment: [String: String]
    public var infoDictionary: [String: Any]
    public var fallbackBaseURL: URL

    public init(environment: [String: String] = [:],
                infoDictionary: [String: Any] = [:],
                fallbackBaseURL: URL = AppConfig.localhostBaseURL) {
        self.environment = environment
        self.infoDictionary = infoDictionary
        self.fallbackBaseURL = fallbackBaseURL
    }

    /// App 进程真实来源：`ProcessInfo` 环境变量 + 主 bundle Info.plist。
    public static var process: AppConfigSource {
        AppConfigSource(environment: ProcessInfo.processInfo.environment,
                        infoDictionary: Bundle.main.infoDictionary ?? [:],
                        fallbackBaseURL: AppConfig.localhostBaseURL)
    }
}

// MARK: - AppConfig

/// 数据层运行配置。
///
/// baseURL 解析优先级：
/// 1. `ProcessInfo.processInfo.environment["DOGIOS_API_BASE_URL"]`
/// 2. Info.plist `DogiosAPIBaseURL`（工程里由 `$(DOGIOS_API_BASE_URL)` 展开）
/// 3. 默认 `http://127.0.0.1:18766`
///
/// 非 localhost 且非 https 时抛 `AppConfigError.insecureBaseURL`。
public struct AppConfig: Equatable {
    public static let environmentBaseURLKey = "DOGIOS_API_BASE_URL"
    public static let infoPlistBaseURLKey = "DogiosAPIBaseURL"
    public static let environmentGoogleMapsAPIKeyKey = "GOOGLE_MAPS_API_KEY"
    public static let infoPlistGoogleMapsAPIKeyKey = "GoogleMapsAPIKey"

    /// 仅用于本机模拟器联调；生产必须用 https 显式覆盖。
    public static let localhostBaseURL = URL(string: "http://127.0.0.1:18766")!

    /// API 根地址，例如 `https://api.example.com` 或 `http://127.0.0.1:18766`。
    public let baseURL: URL
    /// Google Maps 原生 SDK 的 API key；缺失/为空即 nil。
    public let googleMapsAPIKey: String?

    /// 从可注入来源构造配置，可能抛 `AppConfigError`。
    public init(settings: AppConfigSource = .process) throws {
        self.baseURL = try AppConfig.resolveBaseURL(settings: settings)
        self.googleMapsAPIKey = AppConfig.resolveGoogleMapsAPIKey(settings: settings)
    }

    /// 直接给定地址（同样校验 https 规则），便于测试与显式覆盖。
    public init(baseURL: URL, googleMapsAPIKey: String? = nil) throws {
        self.baseURL = try AppConfig.validatedBaseURL(baseURL.absoluteString)
        self.googleMapsAPIKey = AppConfig.normalizedValue(googleMapsAPIKey)
    }

    // MARK: 解析

    /// 按优先级解析 baseURL。
    public static func resolveBaseURL(settings: AppConfigSource) throws -> URL {
        let candidates: [String?] = [
            settings.environment[environmentBaseURLKey],
            settings.infoDictionary[infoPlistBaseURLKey] as? String
        ]
        for candidate in candidates {
            guard let raw = normalizedValue(candidate) else { continue }
            return try validatedBaseURL(raw)
        }
        return settings.fallbackBaseURL
    }

    /// 校验 URL 并返回：只允许 https；http 仅允许 localhost/回环地址。
    public static func validatedBaseURL(_ raw: String) throws -> URL {
        guard let candidate = normalizedValue(raw),
              let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              let host = url.host,
              !host.isEmpty else {
            throw AppConfigError.invalidBaseURL(raw)
        }
        switch scheme {
        case "https":
            return url
        case "http":
            guard isLoopbackHost(host) else {
                throw AppConfigError.insecureBaseURL(raw)
            }
            return url
        default:
            throw AppConfigError.invalidBaseURL(raw)
        }
    }

    /// 是否为本机/回环主机名。
    public static func isLoopbackHost(_ host: String) -> Bool {
        var value = host.lowercased()
        while value.hasPrefix("[") && value.hasSuffix("]") && value.count > 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value == "localhost"
            || value == "127.0.0.1"
            || value == "0.0.0.0"
            || value == "::1"
    }

    /// Google Maps key：环境变量优先，其次 Info.plist；空/未展开视为缺失。
    public static func resolveGoogleMapsAPIKey(settings: AppConfigSource) -> String? {
        let candidates: [String?] = [
            settings.environment[environmentGoogleMapsAPIKeyKey],
            settings.infoDictionary[infoPlistGoogleMapsAPIKeyKey] as? String
        ]
        for candidate in candidates {
            if let value = normalizedValue(candidate) { return value }
        }
        return nil
    }

    /// 去空白；空串、`$(...)` 未展开的构建设置占位符视为「未配置」。
    public static func normalizedValue(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains("$("), !trimmed.contains("${") else { return nil }
        return trimmed
    }

    // MARK: 地图能力

    /// Google Maps 原生 SDK 是否可用（无 SDK 或无 key 均为 `googleUnconfigured`）。
    public var mapProviderStatus: MapProviderStatus {
        MapProviderResolver.resolve(googleMapsAPIKey: googleMapsAPIKey).google
    }

    /// 首期应使用的地图 provider id：`mapkit`（Google 未接通时自动回退）。
    public var preferredMapProviderID: String {
        MapProviderResolver.resolve(googleMapsAPIKey: googleMapsAPIKey).preferredProviderID
    }
}
