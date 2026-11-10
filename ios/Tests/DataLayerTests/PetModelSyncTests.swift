import Foundation
import XCTest
@testable import DogiosDataLayer
@testable import MobileSessionState

@MainActor
final class PetModelSyncTests: DataLayerTestCase {
    private func modelData() -> Data {
        // A self-contained GLB 2.0 JSON chunk with no geometry, sufficient for transport validation.
        var json = Data(#"{"asset":{"version":"2.0"}}"#.utf8)
        while json.count % 4 != 0 { json.append(0x20) }
        let length = UInt32(20 + json.count)
        var bytes = Data([0x67, 0x6c, 0x54, 0x46, 2, 0, 0, 0])
        for value in [length, UInt32(json.count), UInt32(0x4E4F534A)] {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
        }
        bytes.append(json)
        return bytes
    }

    func testSavedBreedModelUsesOwnedAssetWithBearerBeforeDefault() async throws {
        let (client, _) = try makeClient(accessToken: "pet-token")
        let bytes = modelData()
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.authorizationHeader, "Bearer pet-token")
            switch request.url?.path {
            case "/mobile/v1/pet-home":
                XCTAssertEqual(request.queryValue("pet_id"), "pet-1")
                return .json(#"{"pet_id":"pet-1","selected":"personal","default_model":{"format":"glb","url":"/public-assets/website-golden-master.glb"},"personal_model":{"asset_id":"breed-1","format":"glb","url":"https://untrusted.invalid/never-follow","source":"confirmed-breed-reference","is_reference_model":true,"breed_slug":"ragdoll"}}"#)
            case "/mobile/v1/assets/breed-1/download":
                return .init(status: 200, headers: ["Content-Type": "model/gltf-binary"], body: bytes)
            default:
                XCTFail("A saved model must not download the shared golden fallback")
                return .init(status: 404)
            }
        }
        let result = try await MobileAppStore(client: client).petModel(petID: "pet-1")
        XCTAssertEqual(result.data, bytes)
        XCTAssertEqual(result.title, "品种参考模型")
    }

    func testNoSavedModelUsesManifestRegistryURLWithoutBearer() async throws {
        let (client, _) = try makeClient(accessToken: "pet-token")
        let bytes = modelData()
        StubURLProtocol.setHandler { request in
            if request.url?.path == "/mobile/v1/pet-home" {
                XCTAssertEqual(request.authorizationHeader, "Bearer pet-token")
                return .json(#"{"selected":"default","default_model":{"format":"glb","url":"/models/public-id/v000001/model.glb"}}"#)
            }
            XCTAssertEqual(request.url?.path, "/models/public-id/v000001/model.glb")
            XCTAssertNil(request.authorizationHeader)
            return .init(status: 200, headers: ["Content-Type": "model/gltf-binary"], body: bytes)
        }
        let result = try await MobileAppStore(client: client).petModel(petID: nil)
        XCTAssertEqual(result.data, bytes)
        XCTAssertEqual(result.title, "默认宠物形象")
    }

    func testPhotoGeneratedModelIsPersonalEvenWhenBreedSlugMatchesReference() async throws {
        let (client, _) = try makeClient(accessToken: "personal-token")
        let bytes = modelData()
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.authorizationHeader, "Bearer personal-token")
            switch request.url?.path {
            case "/mobile/v1/pet-home":
                XCTAssertEqual(request.queryValue("pet_id"), "personal-pet")
                return .json(#"{"pet_id":"personal-pet","selected":"personal","default_model":{"format":"glb","url":"/public-assets/website-golden-master.glb"},"personal_model":{"asset_id":"personal-1","format":"glb","url":"https://untrusted.invalid/never-follow","source":"photo-generated","is_reference_model":false,"breed_slug":"ragdoll"}}"#)
            case "/mobile/v1/assets/personal-1/download":
                return .init(status: 200, headers: ["Content-Type": "model/gltf-binary"], body: bytes)
            default:
                XCTFail("A generated model must use the owned asset download")
                return .init(status: 404)
            }
        }
        let result = try await MobileAppStore(client: client).petModel(petID: "personal-pet")
        XCTAssertEqual(result.data, bytes)
        XCTAssertEqual(result.title, "专属宠物模型")
    }

    func testArchivePaginationKeepsSelectedPetScope() async throws {
        let (client, _) = try makeClient(accessToken: "archive-token")
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/mobile/v1/assets")
            XCTAssertEqual(request.authorizationHeader, "Bearer archive-token")
            XCTAssertEqual(request.queryValue("pet_id"), "pet-b")
            XCTAssertEqual(request.queryValue("cursor"), "opaque-cursor")
            return .json(#"{"items":[{"asset_id":"model-b","pet_id":"pet-b","kind":"model","source":"photo-generated","is_reference_model":false}],"next_cursor":null}"#)
        }
        let page = try await AssetService(client: client).list(cursor: "opaque-cursor", limit: 30, petId: "pet-b")
        XCTAssertEqual(page.items.first?.petId, "pet-b")
        XCTAssertEqual(page.items.first?.source, "photo-generated")
        XCTAssertEqual(page.items.first?.isReferenceModel, false)
    }

    func testReferenceFieldsDecodeAndLegacyModelStillDecodes() throws {
        let decoder = DogiosJSON.makeDecoder()
        let reference = try decoder.decode(AssetItem.self, from: Data(#"{"asset_id":"breed-1","kind":"model","source":"confirmed-breed-reference","is_reference_model":true,"breed_slug":"ragdoll"}"#.utf8))
        XCTAssertEqual(reference.source, "confirmed-breed-reference")
        XCTAssertEqual(reference.isReferenceModel, true)
        XCTAssertEqual(reference.breedSlug, "ragdoll")
        let legacy = try decoder.decode(AssetItem.self, from: Data(#"{"asset_id":"old-1","kind":"model"}"#.utf8))
        XCTAssertNil(legacy.isReferenceModel)
        XCTAssertNil(legacy.source)
        XCTAssertNil(legacy.petId)
    }

    func testTruncatedGLBAndMismatchedDigestAreRejected() throws {
        var truncated = modelData()
        truncated.removeLast()
        XCTAssertThrowsError(try MobileAppStore.validateGLB(truncated, sha256: nil))
        XCTAssertThrowsError(try MobileAppStore.validateGLB(modelData(), sha256: String(repeating: "0", count: 64)))
        XCTAssertNoThrow(try MobileAppStore.validateGLB(modelData(), sha256: nil))
    }
}
