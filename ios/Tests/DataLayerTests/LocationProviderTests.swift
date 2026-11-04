import Foundation
import XCTest
@testable import DogiosDataLayer

final class LocationProviderTests: DataLayerTestCase {
    // MARK: Google 未配置 → MapKit 回退

    func testNoGoogleKeyYieldsUnconfiguredAndMapKitFallback() {
        let availability = MapProviderResolver.resolve(googleMapsAPIKey: nil)
        XCTAssertEqual(availability.google, .googleUnconfigured)
        XCTAssertEqual(availability.google.statusCode, "google_unconfigured")
        XCTAssertEqual(availability.mapKit, .mapKit)
        XCTAssertEqual(availability.preferredProviderID, "mapkit")

        let provider = MapProviderResolver.preferredProvider(googleMapsAPIKey: nil)
        XCTAssertEqual(provider.providerID, "mapkit")
        XCTAssertEqual(provider.status, .mapKit)
    }

    func testGoogleProviderWithoutSDKIsUnconfigured() {
        let provider = GoogleMapsMapProvider(apiKey: nil)
        XCTAssertEqual(provider.providerID, "google")
        XCTAssertEqual(provider.status, .googleUnconfigured)
        XCTAssertFalse(provider.status.isConfigured)

        // 有 key 但未集成 SDK：仍必须是 google_unconfigured，不能被误判为可用。
        let withKey = GoogleMapsMapProvider(apiKey: "some-key")
        #if canImport(GoogleMaps)
        XCTAssertEqual(withKey.status, .googleConfigured)
        #else
        XCTAssertEqual(withKey.status, .googleUnconfigured)
        #endif
    }

    func testMapKitProviderIsFreeAndAvailable() {
        let provider = MapKitMapProvider()
        XCTAssertEqual(provider.providerID, "mapkit")
        XCTAssertEqual(provider.status, .mapKit)
        XCTAssertEqual(provider.status.providerID, "mapkit")
        XCTAssertTrue(provider.status.isConfigured)
    }

    func testAppConfigReportsGoogleUnconfiguredWithoutSDK() throws {
        let config = try makeTestConfig(googleMapsAPIKey: "config-key")
        #if canImport(GoogleMaps)
        XCTAssertEqual(config.mapProviderStatus, .googleConfigured)
        #else
        XCTAssertEqual(config.mapProviderStatus, .googleUnconfigured)
        #endif
        XCTAssertEqual(config.preferredMapProviderID, "mapkit")
    }

    // MARK: 位置抽象

    func testStaticLocationProviderReturnsFix() async throws {
        let provider = StaticLocationProvider(fix: LocationFix(latitude: 31.23, longitude: 121.47))
        let fix = try await provider.currentFix(timeout: 1)
        XCTAssertEqual(fix.latitude, 31.23)
        XCTAssertEqual(fix.longitude, 121.47)
        XCTAssertEqual(fix.coordinate, GeoCoordinate(lat: 31.23, lon: 121.47))
        XCTAssertEqual(provider.authorizationStatus, .authorizedWhenInUse)
        XCTAssertTrue(provider.authorizationStatus.allowsLocation)
    }

    func testStaticLocationProviderDeniedThrows() async throws {
        let provider = StaticLocationProvider(authorizationStatus: .denied,
                                              fix: nil,
                                              error: LocationError.permissionDenied)
        do {
            _ = try await provider.currentFix(timeout: 1)
            XCTFail("应抛权限错误")
        } catch let error as LocationError {
            XCTAssertEqual(error, .permissionDenied)
        }
    }

    func testNotDeterminedProviderRequestsWhenInUse() {
        let provider = StaticLocationProvider(authorizationStatus: .notDetermined, fix: nil)
        XCTAssertTrue(provider.authorizationStatus.needsAuthorizationRequest)
        provider.requestWhenInUseAuthorization()
        XCTAssertEqual(provider.authorizationStatus, .authorizedWhenInUse)
        XCTAssertFalse(provider.authorizationStatus.needsAuthorizationRequest)
    }

    // MARK: 发现服务与地图解耦

    func testDiscoverySendsCoarseRegionAndClampsRadius() async throws {
        let (client, _) = try makeClient(accessToken: "at-1")
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/mobile/v1/discovery")
            XCTAssertEqual(request.authorizationHeader, "Bearer at-1")
            let body = request.httpBodyJSON
            XCTAssertEqual(body?["enabled"] as? Bool, true)
            XCTAssertEqual(body?["radius_km"] as? Int, 25, "radius_km 上限 25")
            let region = body?["region"] as? [String: Any]
            XCTAssertEqual(region?["lat"] as? Double, 31.23)
            XCTAssertEqual(region?["lon"] as? Double, 121.47)
            return .json("""
            {"enabled": true, "grid": "63:31", "expires_at": "2026-11-05T03:33:21Z", "radius_km": 25}
            """)
        }
        let provider = StaticLocationProvider(fix: LocationFix(latitude: 31.23, longitude: 121.47))
        let fix = try await provider.currentFix(timeout: 1)
        let status = try await DiscoveryService(client: client)
            .setDiscovery(enabled: true, coordinate: fix.coordinate, radiusKm: 100)
        XCTAssertTrue(status.enabled)
        XCTAssertEqual(status.grid, "63:31")
        XCTAssertEqual(status.radiusKm, 25)
    }

    func testDiscoveryDisableSendsNoRegion() async throws {
        let (client, _) = try makeClient(accessToken: "at-1")
        StubURLProtocol.setHandler { request in
            let body = request.httpBodyJSON
            XCTAssertEqual(body?["enabled"] as? Bool, false)
            XCTAssertNil(body?["region"])
            return .json(#"{"enabled": false, "grid": null, "expires_at": null, "radius_km": 5}"#)
        }
        let status = try await DiscoveryService(client: client).disableDiscovery()
        XCTAssertFalse(status.enabled)
        XCTAssertNil(status.grid)
    }

    func testNearbyUsesSavedGridOnly() async throws {
        let (client, _) = try makeClient(accessToken: "at-1")
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/mobile/v1/nearby")
            // 只允许 radius_km，不允许任意中心参数。
            let queryNames = request.queryItems.map(\.name)
            XCTAssertEqual(queryNames, ["radius_km"])
            XCTAssertEqual(request.queryValue("radius_km"), "5")
            return .json("""
            {"items": [{"public_ref": "pub-2",
                        "pet": {"name": "Luna"},
                        "coarse_region": {"grid": "63:31", "label": "上海 · 静安"},
                        "distance_bucket": "1_3km"}],
             "radius_km": 5, "generated_at": "2026-11-04T03:33:21Z"}
            """)
        }
        let nearby = try await DiscoveryService(client: client).nearby(radiusKm: 5)
        XCTAssertEqual(nearby.items.count, 1)
        XCTAssertEqual(nearby.items.first?.coarseRegion?.grid, "63:31")
        XCTAssertEqual(nearby.items.first?.distanceBucket, "1_3km")
    }
}
