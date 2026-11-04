import Foundation

/// 发现 / 附近。
///
/// 边界：位置只以粗网格保存；客户端只上报一次坐标，绝不自行保存精确 GPS，
/// 也不提供任意中心/连续半径扫描（服务端用已保存网格查询）。后端无地图依赖，
/// 本服务不 import MapKit/GoogleMaps。
public final class DiscoveryService: @unchecked Sendable {
    /// 契约 §4：`radius_km` 上限 25。
    public static let maxRadiusKm = 25
    /// 契约 §4：服务端量化网格 0.05°（≈5.5km）。
    public static let gridStepDegrees = 0.05

    private let client: MobileAPIClient

    public init(client: MobileAPIClient) {
        self.client = client
    }

    /// POST `/mobile/v1/discovery`：开关发现并（开启时）上报一次位置。
    /// - Parameters:
    ///   - enabled: 默认关闭；关闭时不带 region。
    ///   - coordinate: 由 `LocationProviding` 提供，服务端立即量化为固定网格。
    ///   - radiusKm: 1...25，超出自动收敛。
    public func setDiscovery(enabled: Bool,
                             coordinate: GeoCoordinate? = nil,
                             radiusKm: Int? = nil) async throws -> DiscoveryStatus {
        struct DiscoveryUpdateRequest: Encodable {
            let enabled: Bool
            let region: GeoCoordinate?
            let radiusKm: Int?
        }
        let clamped = radiusKm.map(DiscoveryService.clampedRadiusKm)
        let region = enabled ? coordinate : nil
        let payload = DiscoveryUpdateRequest(enabled: enabled, region: region, radiusKm: clamped)
        let body = try client.encodeBody(payload)
        return try await client.send(.post("/mobile/v1/discovery", body: body),
                                     as: DiscoveryStatus.self)
    }

    /// 关闭发现（202）。
    public func disableDiscovery() async throws -> DiscoveryStatus {
        try await setDiscovery(enabled: false)
    }

    /// GET `/mobile/v1/nearby?radius_km=`：只用服务端已保存的网格，无任意中心参数。
    public func nearby(radiusKm: Int? = nil) async throws -> NearbyResponse {
        var query: [URLQueryItem] = []
        if let radiusKm {
            query.append(URLQueryItem(name: "radius_km",
                                      value: String(DiscoveryService.clampedRadiusKm(radiusKm))))
        }
        return try await client.send(.get("/mobile/v1/nearby", query: query), as: NearbyResponse.self)
    }

    /// 收敛半径到契约允许范围 1...25。
    public static func clampedRadiusKm(_ value: Int) -> Int {
        min(max(value, 1), maxRadiusKm)
    }
}
