import Foundation
#if canImport(CoreLocation)
import CoreLocation
#endif
#if canImport(MapKit)
import MapKit
#endif

// MARK: - 位置

/// 定位授权状态（只映射 when-in-use 相关状态；本层不申请 Always/后台）。
public enum LocationAuthorizationStatus: String, Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case authorizedWhenInUse
    case authorizedAlways

    /// 是否已获得可用的前台定位授权。
    public var allowsLocation: Bool {
        self == .authorizedWhenInUse || self == .authorizedAlways
    }

    /// 是否需要先请求 when-in-use 授权。
    public var needsAuthorizationRequest: Bool {
        self == .notDetermined
    }
}

/// 一次定位结果（仅用于立刻上报/量化，不落盘）。
public struct LocationFix: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracyMeters: Double?
    public let timestamp: Date?

    public init(latitude: Double,
                longitude: Double,
                horizontalAccuracyMeters: Double? = nil,
                timestamp: Date? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.timestamp = timestamp
    }

    public var coordinate: GeoCoordinate {
        GeoCoordinate(lat: latitude, lon: longitude)
    }
}

public enum LocationError: Error, Equatable, LocalizedError {
    case permissionDenied
    case permissionRestricted
    case servicesDisabled
    case unavailable
    case timeout

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "定位权限被拒绝（可手选城市继续使用附近）"
        case .permissionRestricted: return "系统限制定位"
        case .servicesDisabled: return "设备定位服务不可用"
        case .unavailable: return "暂时拿不到位置"
        case .timeout: return "定位超时"
        }
    }
}

/// 位置能力抽象：只暴露授权状态与一次性定位，不采集后台轨迹。
public protocol LocationProviding: AnyObject {
    var authorizationStatus: LocationAuthorizationStatus { get }
    func requestWhenInUseAuthorization()
    func currentFix(timeout: TimeInterval) async throws -> LocationFix
}

public extension LocationProviding {
    func currentFix() async throws -> LocationFix {
        try await currentFix(timeout: 15)
    }
}

// MARK: - CoreLocation 实现

#if canImport(CoreLocation)
/// `CoreLocation` provider：**只申请 when-in-use**，不申请 Always、不开启后台更新。
public final class CoreLocationProvider: NSObject, LocationProviding, @unchecked Sendable {
    private let manager: CLLocationManager
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LocationFix, Error>?
    private var timeoutTask: Task<Void, Never>?

    public override init() {
        self.manager = CLLocationManager()
        super.init()
        manager.delegate = self
        // 粗精度即可：附近发现只需要固定网格（≈5.5km），不需要街道级定位。
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    public var authorizationStatus: LocationAuthorizationStatus {
        CoreLocationProvider.map(manager.authorizationStatus)
    }

    /// 仅在 notDetermined 时请求 **when-in-use**；不申请 Always/后台。
    public func requestWhenInUseAuthorization() {
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    public func currentFix(timeout: TimeInterval = 15) async throws -> LocationFix {
        #if os(iOS) || os(macOS)
        guard CLLocationManager.locationServicesEnabled() else {
            throw LocationError.servicesDisabled
        }
        #endif
        let status = authorizationStatus
        switch status {
        case .denied:
            throw LocationError.permissionDenied
        case .restricted:
            throw LocationError.permissionRestricted
        case .notDetermined, .authorizedWhenInUse, .authorizedAlways:
            break
        }

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            let alreadyWaiting = self.continuation != nil
            if !alreadyWaiting {
                self.continuation = continuation
            }
            lock.unlock()
            guard !alreadyWaiting else {
                continuation.resume(throwing: LocationError.unavailable)
                return
            }

            if status.allowsLocation {
                manager.requestLocation()
            } else {
                // 未决定：只申请 when-in-use；授权结果由 delegate 回调后再发起定位。
                manager.requestWhenInUseAuthorization()
            }
            let task = Task { [weak self] in
                let nanoseconds = UInt64(max(timeout, 0.1) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                self?.finish(.failure(LocationError.timeout))
            }
            lock.lock()
            timeoutTask = task
            lock.unlock()
        }
    }

    private func finish(_ result: Result<LocationFix, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let task = timeoutTask
        timeoutTask = nil
        lock.unlock()
        task?.cancel()
        continuation?.resume(with: result)
    }

    private static func map(_ status: CLAuthorizationStatus) -> LocationAuthorizationStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorizedWhenInUse: return .authorizedWhenInUse
        case .authorizedAlways: return .authorizedAlways
        @unknown default: return .notDetermined
        }
    }
}

extension CoreLocationProvider: CLLocationManagerDelegate {
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let mapped = CoreLocationProvider.map(manager.authorizationStatus)
        switch mapped {
        case .denied:
            finish(.failure(LocationError.permissionDenied))
            return
        case .restricted:
            finish(.failure(LocationError.permissionRestricted))
            return
        default:
            break
        }
        // 用户在系统弹窗里同意后，补发一次请求（currentFix 里之前那次可能未发出）。
        guard mapped.allowsLocation else { return }
        lock.lock()
        let waiting = continuation != nil
        lock.unlock()
        if waiting {
            manager.requestLocation()
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            finish(.failure(LocationError.unavailable))
            return
        }
        let fix = LocationFix(latitude: location.coordinate.latitude,
                              longitude: location.coordinate.longitude,
                              horizontalAccuracyMeters: location.horizontalAccuracy,
                              timestamp: location.timestamp)
        finish(.success(fix))
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let clError = error as? CLError, clError.code == .denied {
            finish(.failure(LocationError.permissionDenied))
        } else {
            finish(.failure(LocationError.unavailable))
        }
    }
}
#endif

// MARK: - 测试/预览用静态 provider

/// 固定结果的 provider（预览、单测、拒绝定位时手选城市后的替身）。
public final class StaticLocationProvider: LocationProviding, @unchecked Sendable {
    public var authorizationStatus: LocationAuthorizationStatus
    public var fix: LocationFix?
    public var error: Error?

    public init(authorizationStatus: LocationAuthorizationStatus = .authorizedWhenInUse,
                fix: LocationFix? = LocationFix(latitude: 31.23, longitude: 121.47),
                error: Error? = nil) {
        self.authorizationStatus = authorizationStatus
        self.fix = fix
        self.error = error
    }

    public func requestWhenInUseAuthorization() {
        if authorizationStatus == .notDetermined {
            authorizationStatus = .authorizedWhenInUse
        }
    }

    public func currentFix(timeout: TimeInterval) async throws -> LocationFix {
        if let error { throw error }
        guard let fix else { throw LocationError.unavailable }
        return fix
    }
}

// MARK: - 地图能力状态（不渲染地图）

/// 地图 provider 能力状态。数据层只报告「能力」，画地图属于 UI 层。
public enum MapProviderStatus: Equatable, Sendable {
    /// MapKit：系统内置、免 key，首期默认。
    case mapKit
    /// Google Maps 原生 SDK 已接入且配置了 key（本轮不添加 SDK 依赖，实际不会出现）。
    case googleConfigured
    /// Google Maps 未配置（无 SDK 或无 key）→ 必须回退 MapKit。
    case googleUnconfigured

    /// provider 标识：`mapkit` / `google`。
    public var providerID: String {
        switch self {
        case .mapKit: return "mapkit"
        case .googleConfigured, .googleUnconfigured: return "google"
        }
    }

    /// 稳定字符串标识，便于日志/上报。
    public var statusCode: String {
        switch self {
        case .mapKit: return "mapkit"
        case .googleConfigured: return "google_configured"
        case .googleUnconfigured: return "google_unconfigured"
        }
    }

    public var isConfigured: Bool {
        self != .googleUnconfigured
    }
}

/// 地图 provider 抽象：只暴露 provider 标识与配置状态。
public protocol MapProviding: AnyObject {
    var providerID: String { get }
    var status: MapProviderStatus { get }
}

/// MapKit provider：免 key，首期默认。
public final class MapKitMapProvider: MapProviding, @unchecked Sendable {
    public init() {}
    public var providerID: String { "mapkit" }
    public var status: MapProviderStatus { .mapKit }
}

/// Google Maps provider：**不添加 SDK 依赖**，用 `#if canImport(GoogleMaps)` 隔离。
/// 本仓库未集成 Google Maps SDK 与 key，因此状态恒为 `googleUnconfigured`。
public final class GoogleMapsMapProvider: MapProviding, @unchecked Sendable {
    public let apiKey: String?

    public init(apiKey: String? = nil) {
        self.apiKey = apiKey
    }

    public var providerID: String { "google" }

    public var status: MapProviderStatus {
        #if canImport(GoogleMaps)
        return (apiKey?.isEmpty == false) ? .googleConfigured : .googleUnconfigured
        #else
        return .googleUnconfigured
        #endif
    }
}

/// 地图能力可用性快照。
public struct MapProviderAvailability: Equatable, Sendable {
    public let mapKit: MapProviderStatus
    public let google: MapProviderStatus
    /// 实际应使用的 provider id（Google 未配置时回退 `mapkit`）。
    public let preferredProviderID: String

    public init(mapKit: MapProviderStatus, google: MapProviderStatus, preferredProviderID: String) {
        self.mapKit = mapKit
        self.google = google
        self.preferredProviderID = preferredProviderID
    }
}

/// 解析地图能力：无 key / 无 SDK → `googleUnconfigured` 并回退 MapKit。
public enum MapProviderResolver {
    public static func resolve(googleMapsAPIKey: String?) -> MapProviderAvailability {
        let trimmed = googleMapsAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasKey = !(trimmed?.isEmpty ?? true)

        let google: MapProviderStatus
        #if canImport(GoogleMaps)
        google = hasKey ? .googleConfigured : .googleUnconfigured
        #else
        _ = hasKey
        google = .googleUnconfigured
        #endif

        return MapProviderAvailability(mapKit: .mapKit,
                                       google: google,
                                       preferredProviderID: google == .googleConfigured ? "google" : "mapkit")
    }

    /// 首期实际 provider：Google 未接通时始终回退 MapKit（免 key）。
    public static func preferredProvider(googleMapsAPIKey: String?) -> MapProviding {
        if resolve(googleMapsAPIKey: googleMapsAPIKey).google == .googleConfigured {
            return GoogleMapsMapProvider(apiKey: googleMapsAPIKey)
        }
        return MapKitMapProvider()
    }
}
