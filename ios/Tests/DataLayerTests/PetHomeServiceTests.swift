import Foundation
import XCTest
@testable import DogiosDataLayer

final class PetHomeServiceTests: DataLayerTestCase {
    private func defaultModel() -> DefaultModel {
        DefaultModel(role: "default",
                     isStatic: true,
                     isDefault: true,
                     format: "glb",
                     mime: "model/gltf-binary",
                     bytes: 46_036_096,
                     sha256: "96efb8f2",
                     url: "/public-assets/website-golden-master.glb",
                     source: "website-golden-master")
    }

    private func personalModel(format: String = "glb") -> PersonalModel {
        PersonalModel(assetId: "asset-9",
                      format: format,
                      url: "/mobile/v1/assets/asset-9/download",
                      source: "app",
                      sourceJobId: "job-7")
    }

    private func manifest(selected: String,
                          personal: PersonalModel?) -> PetHomeManifest {
        PetHomeManifest(petId: "pet-1",
                        manifestVersion: 1,
                        selected: selected,
                        avatarUrl: nil,
                        defaultModel: defaultModel(),
                        personalModel: personal)
    }

    // MARK: 解析规则

    func testPersonalGLBIsPreferred() {
        let selection = PetHomeService.resolve(manifest(selected: "personal",
                                                        personal: personalModel()))
        XCTAssertEqual(selection, .personal(personalModel()))
        XCTAssertFalse(selection.isDefault)
        XCTAssertNil(selection.fallbackReason)
        XCTAssertTrue(selection.requiresAuthorization)
        XCTAssertEqual(selection.remoteURLString, "/mobile/v1/assets/asset-9/download")
        XCTAssertEqual(selection.format, "glb")
    }

    func testPersonalNonGLBFallsBackToDefaultWithReason() {
        let selection = PetHomeService.resolve(manifest(selected: "personal",
                                                        personal: personalModel(format: "usdz")))
        XCTAssertEqual(selection, .default(defaultModel(),
                                          fallbackReason: .unsupportedPersonalFormat))
        XCTAssertTrue(selection.isDefault)
        XCTAssertEqual(selection.fallbackReason, .unsupportedPersonalFormat)
        XCTAssertFalse(selection.requiresAuthorization)
        XCTAssertEqual(selection.remoteURLString, "/public-assets/website-golden-master.glb")
    }

    func testNoPersonalModelUsesDefaultWithoutFallbackReason() {
        let selection = PetHomeService.resolve(manifest(selected: "default", personal: nil))
        XCTAssertEqual(selection, .default(defaultModel(), fallbackReason: nil))
        XCTAssertTrue(selection.isDefault)
        XCTAssertNil(selection.fallbackReason)
        XCTAssertEqual(selection.format, "glb")
    }

    func testSelectedPersonalButMissingPersonalModelFallsBackWithReason() {
        let selection = PetHomeService.resolve(manifest(selected: "personal", personal: nil))
        XCTAssertEqual(selection, .default(defaultModel(), fallbackReason: .personalMissing))
        XCTAssertEqual(selection.fallbackReason, .personalMissing)
    }

    // MARK: 网络

    func testPetHomeFetchesManifestAndResolvesPersonal() async throws {
        let (client, _) = try makeClient(accessToken: "token")
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/mobile/v1/pet-home")
            XCTAssertEqual(request.queryValue("pet_id"), "pet-1")
            XCTAssertEqual(request.authorizationHeader, "Bearer token")
            return .json("""
            {
              "pet_id": "pet-1", "manifest_version": 1, "selected": "personal",
              "default_model": {"format": "glb", "url": "/public-assets/website-golden-master.glb"},
              "personal_model": {"asset_id": "asset-9", "format": "glb",
                                 "url": "/mobile/v1/assets/asset-9/download"}
            }
            """)
        }
        let result = try await PetHomeService(client: client).petHome(petId: "pet-1")
        XCTAssertEqual(result.manifest.petId, "pet-1")
        XCTAssertEqual(result.model, .personal(result.manifest.personalModel!))
        XCTAssertFalse(result.model.isDefault)
    }

    func testPetHomeNetworkFallbackForUnsupportedPersonalFormat() async throws {
        let (client, _) = try makeClient(accessToken: "token")
        StubURLProtocol.setHandler { _ in
            .json("""
            {
              "pet_id": "pet-1", "selected": "personal",
              "default_model": {"format": "glb", "url": "/public-assets/website-golden-master.glb"},
              "personal_model": {"asset_id": "asset-9", "format": "usdz",
                                 "url": "/mobile/v1/assets/asset-9/download"}
            }
            """)
        }
        let result = try await PetHomeService(client: client).petHome(petId: "pet-1")
        XCTAssertTrue(result.model.isDefault)
        XCTAssertEqual(result.model.fallbackReason, .unsupportedPersonalFormat)
    }

    func testPetsList() async throws {
        let (client, _) = try makeClient(accessToken: "token")
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/mobile/v1/pets")
            return .json(#"{"pets": [{"pet_id": "pet-1", "name": "Milo", "species": "dog"}]}"#)
        }
        let list = try await PetHomeService(client: client).pets()
        XCTAssertEqual(list.pets.count, 1)
        XCTAssertEqual(list.pets.first?.name, "Milo")
    }
}
