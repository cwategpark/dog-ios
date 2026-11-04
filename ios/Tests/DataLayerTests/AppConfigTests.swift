import Foundation
import XCTest
@testable import DogiosDataLayer

final class AppConfigTests: DataLayerTestCase {
    // MARK: baseURL 优先级

    func testDefaultsToLocalhostWhenNothingConfigured() throws {
        let config = try AppConfig(settings: AppConfigSource())
        XCTAssertEqual(config.baseURL.absoluteString, "http://127.0.0.1:18766")
        XCTAssertNil(config.googleMapsAPIKey)
        XCTAssertEqual(config.mapProviderStatus, .googleUnconfigured)
        XCTAssertEqual(config.preferredMapProviderID, "mapkit")
    }

    func testEnvironmentWinsOverInfoPlist() throws {
        let config = try AppConfig(settings: AppConfigSource(
            environment: ["DOGIOS_API_BASE_URL": "https://env.example.com"],
            infoDictionary: ["DogiosAPIBaseURL": "https://info.example.com"]
        ))
        XCTAssertEqual(config.baseURL.absoluteString, "https://env.example.com")
    }

    func testInfoPlistUsedWhenEnvironmentMissing() throws {
        let config = try AppConfig(settings: AppConfigSource(
            infoDictionary: ["DogiosAPIBaseURL": "https://info.example.com"]
        ))
        XCTAssertEqual(config.baseURL.absoluteString, "https://info.example.com")
    }

    func testBlankEnvironmentFallsThroughToInfoPlist() throws {
        let config = try AppConfig(settings: AppConfigSource(
            environment: ["DOGIOS_API_BASE_URL": "   "],
            infoDictionary: ["DogiosAPIBaseURL": "https://info.example.com"]
        ))
        XCTAssertEqual(config.baseURL.absoluteString, "https://info.example.com")
    }

    func testUnexpandedBuildSettingIsIgnored() throws {
        // Info.plist 里 $(DOGIOS_API_BASE_URL) 未展开时不能把占位符当 URL。
        let config = try AppConfig(settings: AppConfigSource(
            infoDictionary: ["DogiosAPIBaseURL": "$(DOGIOS_API_BASE_URL)"]
        ))
        XCTAssertEqual(config.baseURL.absoluteString, "http://127.0.0.1:18766")
    }

    // MARK: https 规则

    func testInsecureRemoteHTTPThrows() {
        XCTAssertThrowsError(try AppConfig(settings: AppConfigSource(
            environment: ["DOGIOS_API_BASE_URL": "http://192.168.1.10:18766"]
        ))) { error in
            XCTAssertEqual(error as? AppConfigError, .insecureBaseURL("http://192.168.1.10:18766"))
        }
    }

    func testInsecureCustomDomainHTTPThrows() {
        XCTAssertThrowsError(try AppConfig(settings: AppConfigSource(
            environment: ["DOGIOS_API_BASE_URL": "http://api.example.com"]
        ))) { error in
            guard case .insecureBaseURL = (error as? AppConfigError) else {
                return XCTFail("应为 insecureBaseURL，实际 \(error)")
            }
        }
    }

    func testLocalhostHTTPIsAllowed() throws {
        for raw in ["http://127.0.0.1:18766", "http://localhost:8787", "http://[::1]:18766"] {
            let config = try AppConfig(settings: AppConfigSource(
                environment: ["DOGIOS_API_BASE_URL": raw]
            ))
            XCTAssertEqual(config.baseURL.absoluteString, raw, "\(raw) 应被允许")
        }
    }

    func testHTTPSRemoteIsAllowed() throws {
        let config = try AppConfig(settings: AppConfigSource(
            environment: ["DOGIOS_API_BASE_URL": "https://api.dogios.example"]
        ))
        XCTAssertEqual(config.baseURL.absoluteString, "https://api.dogios.example")
    }

    func testInvalidBaseURLThrows() {
        XCTAssertThrowsError(try AppConfig(settings: AppConfigSource(
            environment: ["DOGIOS_API_BASE_URL": "not a url"]
        ))) { error in
            guard case .invalidBaseURL = (error as? AppConfigError) else {
                return XCTFail("应为 invalidBaseURL，实际 \(error)")
            }
        }
    }

    func testNonHTTPSSchemeThrows() {
        XCTAssertThrowsError(try AppConfig(settings: AppConfigSource(
            environment: ["DOGIOS_API_BASE_URL": "ftp://api.example.com"]
        ))) { error in
            guard case .invalidBaseURL = (error as? AppConfigError) else {
                return XCTFail("应为 invalidBaseURL，实际 \(error)")
            }
        }
    }

    func testDirectURLInitValidatesToo() throws {
        XCTAssertThrowsError(try AppConfig(baseURL: try XCTUnwrap(URL(string: "http://10.0.0.2:18766"))))
        let config = try AppConfig(baseURL: try XCTUnwrap(URL(string: "https://api.example.com")))
        XCTAssertEqual(config.baseURL.absoluteString, "https://api.example.com")
    }

    // MARK: Google Maps key / 能力状态

    func testGoogleMapsKeyFromInfoPlist() throws {
        let config = try AppConfig(settings: AppConfigSource(
            infoDictionary: ["GoogleMapsAPIKey": "plist-key"]
        ))
        XCTAssertEqual(config.googleMapsAPIKey, "plist-key")
    }

    func testGoogleMapsKeyEnvironmentWins() throws {
        let config = try AppConfig(settings: AppConfigSource(
            environment: ["GOOGLE_MAPS_API_KEY": "env-key"],
            infoDictionary: ["GoogleMapsAPIKey": "plist-key"]
        ))
        XCTAssertEqual(config.googleMapsAPIKey, "env-key")
    }

    func testMissingGoogleMapsKeyIsUnconfigured() throws {
        let config = try makeTestConfig()
        XCTAssertNil(config.googleMapsAPIKey)
        XCTAssertEqual(config.mapProviderStatus, .googleUnconfigured)
        XCTAssertEqual(config.preferredMapProviderID, "mapkit")
    }

    func testGoogleMapsKeyWithoutSDKIsStillUnconfigured() throws {
        let config = try makeTestConfig(googleMapsAPIKey: "test-key")
        XCTAssertEqual(config.googleMapsAPIKey, "test-key")
        #if canImport(GoogleMaps)
        XCTAssertEqual(config.mapProviderStatus, .googleConfigured)
        #else
        // 本轮不添加 Google Maps SDK 依赖：有 key 也只能是 google_unconfigured。
        XCTAssertEqual(config.mapProviderStatus, .googleUnconfigured)
        XCTAssertEqual(config.preferredMapProviderID, "mapkit")
        #endif
    }
}
