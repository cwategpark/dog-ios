import Foundation
import XCTest
@testable import DogiosDataLayer

final class AssetServiceTests: DataLayerTestCase {
    func testDownloadSendsBearerAndReturnsBytes() async throws {
        let (client, _) = try makeClient(accessToken: "access-private")
        let payload = Data([0x47, 0x4C, 0x42, 0x01, 0x02])
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/mobile/v1/assets/asset-1/download")
            XCTAssertEqual(request.authorizationHeader, "Bearer access-private")
            return StubURLProtocol.StubResponse(status: 200,
                                                headers: ["Content-Type": "application/octet-stream"],
                                                body: payload)
        }
        let service = AssetService(client: client)
        let data = try await service.download(assetId: "asset-1")
        XCTAssertEqual(data, payload)
    }

    func testDownloadForbiddenIsForbidden() async throws {
        let (client, _) = try makeClient(accessToken: "access-private")
        StubURLProtocol.setHandler { _ in
            .json(#"{"detail": "FORBIDDEN"}"#, status: 403)
        }
        let service = AssetService(client: client)
        do {
            _ = try await service.download(assetId: "asset-1")
            XCTFail("应抛 forbidden")
        } catch let error as MobileAPIError {
            XCTAssertEqual(error.kind, .forbidden)
            XCTAssertFalse(error.isUnauthorized)
        }
    }

    func testNonOwnerDownloadIsNotFound() async throws {
        let (client, _) = try makeClient(accessToken: "access-private")
        StubURLProtocol.setHandler { _ in
            .json(#"{"detail": "NOT_FOUND"}"#, status: 404)
        }
        let service = AssetService(client: client)
        do {
            _ = try await service.download(assetId: "someone-elses-asset")
            XCTFail("应抛 notFound")
        } catch let error as MobileAPIError {
            XCTAssertEqual(error.kind, .notFound)
            XCTAssertEqual(error.code, "NOT_FOUND")
        }
    }

    func testDownloadAlwaysAuthenticatesEvenWithDownloadURLInList() async throws {
        let (client, _) = try makeClient(accessToken: "access-private")
        StubURLProtocol.setHandler { request in
            // 即便列表给了 download_url，取字节也必须走认证接口而不是公开链接。
            XCTAssertEqual(request.authorizationHeader, "Bearer access-private")
            XCTAssertTrue(request.url?.path.hasSuffix("/download") == true)
            return StubURLProtocol.StubResponse(status: 200, headers: [:], body: Data([1]))
        }
        let service = AssetService(client: client)
        let item = AssetItem(assetId: "asset-1", downloadUrl: "/mobile/v1/assets/asset-1/download")
        _ = try await service.data(for: item)
    }

    // MARK: 游标分页

    func testListSendsCursorAndParsesNextCursor() async throws {
        let (client, _) = try makeClient(accessToken: "access-private")
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/mobile/v1/assets")
            XCTAssertEqual(request.queryValue("kind"), "model")
            XCTAssertEqual(request.queryValue("cursor"), "cursor-2")
            XCTAssertEqual(request.queryValue("limit"), "20")
            return .json("""
            {"items": [
               {"asset_id": "a-3", "kind": "model", "format": "glb", "bytes": 10,
                "created_at": "2026-11-04T03:33:21Z",
                "download_url": "/mobile/v1/assets/a-3/download"}
             ], "next_cursor": "cursor-3"}
            """)
        }
        let service = AssetService(client: client)
        let page = try await service.list(kind: "model", cursor: "cursor-2", limit: 20)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items.first?.assetId, "a-3")
        XCTAssertEqual(page.nextCursor, "cursor-3")
        XCTAssertTrue(page.hasMore)
    }

    func testWebsitePreviewListAndDownloadUseSameVerifiedAccount() async throws {
        let (client, _) = try makeClient(accessToken: "preview-owner")
        let payload = Data([0x89, 0x50, 0x4E, 0x47])
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.authorizationHeader, "Bearer preview-owner")
            if request.url?.path == "/mobile/v1/assets" {
                XCTAssertEqual(request.queryValue("kind"), "tryon")
                XCTAssertEqual(request.queryValue("pet_id"), "pet-1")
                return .json("""
                {"items":[{"asset_id":"preview-1","pet_id":"pet-1","kind":"tryon",
                  "kind_role":"generated","format":"png","mime":"image/png",
                  "download_url":"/mobile/v1/assets/preview-1/download"}],"next_cursor":null}
                """)
            }
            XCTAssertEqual(request.url?.path, "/mobile/v1/assets/preview-1/download")
            return StubURLProtocol.StubResponse(status: 200,
                                                headers: ["Content-Type": "image/png"], body: payload)
        }
        let service = AssetService(client: client)
        let page = try await service.list(kind: "tryon", petId: "pet-1")
        let preview = try XCTUnwrap(page.items.first)
        XCTAssertEqual(preview.kind, "tryon")
        XCTAssertEqual(preview.petId, "pet-1")
        let downloaded = try await service.data(for: preview)
        XCTAssertEqual(downloaded, payload)
    }

    func testListLastPageHasNoCursor() async throws {
        let (client, _) = try makeClient(accessToken: "access-private")
        StubURLProtocol.setHandler { request in
            XCTAssertNil(request.queryValue("cursor"))
            XCTAssertNil(request.queryValue("kind"))
            XCTAssertNil(request.queryValue("limit"))
            return .json(#"{"items": [], "next_cursor": null}"#)
        }
        let service = AssetService(client: client)
        let page = try await service.list()
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertNil(page.nextCursor)
        XCTAssertFalse(page.hasMore)
    }

    func testManifest() async throws {
        let (client, _) = try makeClient(accessToken: "access-private")
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/mobile/v1/assets/asset-1/manifest")
            XCTAssertEqual(request.authorizationHeader, "Bearer access-private")
            return .json("""
            {"asset_id": "asset-1", "format": "glb", "mime": "model/gltf-binary",
             "bytes": 46036096, "sha256": "sha", "source_job_id": "job-1", "available": true}
            """)
        }
        let service = AssetService(client: client)
        let manifest = try await service.manifest(assetId: "asset-1")
        XCTAssertEqual(manifest.assetId, "asset-1")
        XCTAssertEqual(manifest.bytes, 46_036_096)
        XCTAssertTrue(manifest.isAvailable)
    }
}
