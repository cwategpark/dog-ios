import Foundation
import XCTest
@testable import DogiosDataLayer

final class AccountSyncDataLayerTests: DataLayerTestCase {
    private let decoder = DogiosJSON.makeDecoder()

    // MARK: Logistics

    func testLogisticsRequestUsesBearerCursorAndNoTargetIdentity() async throws {
        let (client, _) = try makeClient(accessToken: "logistics-token")
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/mobile/v1/orders/logistics")
            XCTAssertEqual(request.queryItems.map(\.name), ["cursor"])
            XCTAssertEqual(request.queryValue("cursor"), "cursor-1")
            XCTAssertEqual(request.authorizationHeader, "Bearer logistics-token")
            XCTAssertNil(request.queryValue("email"))
            XCTAssertNil(request.queryValue("customer_id"))
            XCTAssertNil(request.queryValue("user_id"))
            return .json("""
            {"items":[{
              "id":"order-1","name":"Harness order","processed_at":"2026-11-10T10:00:00Z",
              "status":"custom_status",
              "items":[{"title":"Harness","quantity":2,"image_url":"https://cdn.example.test/a.jpg"}],
              "shipments":[{
                "id":"ship-1","status":"future_carrier_status","updated_at":"2026-11-11T00:00:00Z",
                "tracking":[
                  {"company":"DHL","number":"123","url":"https://track.example.test/a"},
                  {"company":"Bad","number":"x","url":"http://insecure.example.test/x"},
                  {"company":"Bad2","url":"javascript:alert(1)"}
                ]
              }]
            }],"next_cursor":"next-1"}
            """)
        }
        let page = try await LogisticsService(client: client).orders(cursor: "cursor-1")
        XCTAssertEqual(page.items.count, 1)
        let order = try XCTUnwrap(page.items.first)
        XCTAssertEqual(order.id, "order-1")
        XCTAssertEqual(order.status, "custom_status")
        XCTAssertEqual(order.items.first?.quantity, 2)
        XCTAssertEqual(order.items.first?.imageUrl?.absoluteString, "https://cdn.example.test/a.jpg")
        let shipment = try XCTUnwrap(order.shipments.first)
        XCTAssertEqual(shipment.status, "future_carrier_status")
        XCTAssertEqual(shipment.tracking.count, 3)
        XCTAssertEqual(shipment.tracking[0].url?.absoluteString, "https://track.example.test/a")
        XCTAssertNil(shipment.tracking[1].url)
        XCTAssertNil(shipment.tracking[2].url)
        XCTAssertEqual(page.nextCursor, "next-1")
        XCTAssertTrue(page.hasMore)
    }

    func testLogisticsWithoutCursorAndEmptyHistoryDecodes() async throws {
        let (client, _) = try makeClient(accessToken: "logistics-token")
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/mobile/v1/orders/logistics")
            XCTAssertTrue(request.queryItems.isEmpty)
            return .json("""
            {"items":[],"next_cursor":null}
            """)
        }
        let page = try await LogisticsService(client: client).orders()
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertFalse(page.hasMore)
    }

    func testMalformedLogisticsCannotBecomeEmptyOrderHistory() throws {
        for json in [#"{}"#, #"{"detail":"unexpected"}"#,
                     #"{"items":[{"id":"order-1","name":"Order","processed_at":"now"}]}"#] {
            XCTAssertThrowsError(try decoder.decode(LogisticsPage.self, from: Data(json.utf8)))
        }
    }

    func testLogistics503PreservesDetailCodes() async throws {
        let (client, _) = try makeClient(accessToken: "logistics-token")
        for code in ["logistics_not_configured", "logistics_temporarily_unavailable"] {
            StubURLProtocol.setHandler { _ in
                .json("{\"detail\":\"\(code)\"}", status: 503)
            }
            do {
                _ = try await LogisticsService(client: client).orders()
                XCTFail("Expected 503 for \(code)")
            } catch let error as MobileAPIError {
                XCTAssertEqual(error.kind, .unavailable)
                XCTAssertEqual(error.code, code)
            }
        }
    }

    // MARK: Asset/model source compatibility

    func testTextGeneratedAndUnknownSourcesRemainDecodable() throws {
        let page = try decoder.decode(AssetPage.self, from: Data("""
        {"items":[
          {"asset_id":"upload-1","kind":"photo","kind_role":"upload",
           "source":"text-generated","is_reference_model":false,"pet_id":"pet-1"},
          {"asset_id":"future-1","kind":"photo","source":"future-v9"}
        ],"next_cursor":null}
        """.utf8))
        XCTAssertEqual(page.items[0].kindRole, "upload")
        XCTAssertEqual(page.items[0].source, "text-generated")
        XCTAssertEqual(page.items[0].petId, "pet-1")
        XCTAssertEqual(page.items[1].source, "future-v9")

        let legacy = try decoder.decode(AssetItem.self, from: Data(#"{"asset_id":"old-1"}"#.utf8))
        XCTAssertNil(legacy.source)
        XCTAssertNil(legacy.kindRole)

        let personal = try decoder.decode(PersonalModel.self, from: Data("""
        {"asset_id":"a-1","format":"glb","url":"/mobile/v1/assets/a-1/download",
         "source":"text-generated","is_reference_model":false,"breed_slug":"ragdoll"}
        """.utf8))
        XCTAssertEqual(personal.source, "text-generated")
        XCTAssertEqual(personal.breedSlug, "ragdoll")

        let futureModel = try decoder.decode(PrivateModel.self, from: Data("""
        {"asset_id":"11111111-1111-1111-1111-111111111111",
         "archive_asset_id":"0123456789abcdef0123456789abcdef",
         "pet_id":"pet-1","name":"Future model","source":"future-v9"}
        """.utf8))
        XCTAssertEqual(futureModel.source, "future-v9")
        XCTAssertEqual(futureModel.status, "unknown")
        XCTAssertNil(futureModel.revision)
    }

    // MARK: Private model registry

    func testPrivateModelsListDecodesRegistryAndArchiveIDs() async throws {
        let (client, _) = try makeClient(accessToken: "models-token")
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/mobile/v1/models")
            XCTAssertEqual(request.authorizationHeader, "Bearer models-token")
            return .json("""
            {"items":[{
              "asset_id":"11111111-1111-1111-1111-111111111111",
              "archive_asset_id":"0123456789abcdef0123456789abcdef",
              "pet_id":"pet-1","name":"Personal model","revision":3,
              "visibility":"private","status":"ready","mime_type":"model/gltf-binary",
              "sha256":"abc123","size_bytes":1234,
              "download_url":"/mobile/v1/models/registry-1/download",
              "created_at":1794048000.5,"source":"text-generated",
              "is_reference_model":false,"breed_slug":"ragdoll"
            }]}
            """)
        }
        let response = try await PrivateModelsService(client: client).list()
        let model = try XCTUnwrap(response.items.first)
        XCTAssertEqual(model.assetId, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(model.archiveAssetId, "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(model.petId, "pet-1")
        XCTAssertEqual(model.revision, "3")
        XCTAssertEqual(model.status, "ready")
        XCTAssertEqual(model.mimeType, "model/gltf-binary")
        XCTAssertEqual(model.sizeBytes, 1234)
        XCTAssertEqual(model.source, "text-generated")
        XCTAssertEqual(model.isReferenceModel, false)
        XCTAssertNotNil(model.createdAt)
    }

    func testPrivateModelDownloadUsesArchiveIDAndBearer() async throws {
        let (client, _) = try makeClient(accessToken: "models-token")
        let model = PrivateModel(
            assetId: "11111111-1111-1111-1111-111111111111",
            archiveAssetId: "0123456789abcdef0123456789abcdef",
            petId: "pet-1",
            name: "Personal model",
            downloadUrl: "/mobile/v1/models/registry-1/download",
            source: "text-generated")
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path,
                           "/mobile/v1/assets/0123456789abcdef0123456789abcdef/download")
            XCTAssertEqual(request.authorizationHeader, "Bearer models-token")
            return StubURLProtocol.StubResponse(status: 200, headers: [:], body: Data([7, 8, 9]))
        }
        let data = try await PrivateModelsService(client: client).download(model: model)
        XCTAssertEqual(data, Data([7, 8, 9]))
    }
}
