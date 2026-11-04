import Foundation
import XCTest
@testable import DogiosDataLayer

/// Decode the checked-in fixtures captured from a real uvicorn backend over HTTP.
///
/// These are the exact payload shapes produced by the FastAPI app in this repo (times are Unix
/// seconds, claim field is `challenge_id`, blocks use `user_public_ref` + `created_at`, message
/// pages carry `next_before` + `next_before_id`, and no-pet public responses use `name: null`).
/// Tokens/dev codes in the auth fixtures are redacted placeholders; every other field is real.
final class RealBackendFixturesTests: DataLayerTestCase {
    private let decoder = DogiosJSON.makeDecoder()

    private func fixtureURL(_ name: String) -> URL {
        // Fixtures live in ios/Tests/Fixtures (outside the SwiftPM test target path). The
        // frontend-import Package.swift does not declare them as bundle resources, so resolve
        // the sibling source directory from #filePath instead of Bundle.module.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("\(name).json")
    }

    private func decodeFixture<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        let url = fixtureURL(name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing fixture \(name).json")
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    func testAuthAndIdentityFixtures() throws {
        let challenge = try decodeFixture(EmailChallenge.self, "email_start")
        XCTAssertFalse(challenge.challengeId.isEmpty)
        XCTAssertEqual(challenge.purpose, "mobile_login")
        XCTAssertNotNil(challenge.expiresAt)
        XCTAssertEqual(challenge.delivery, "outbox")

        let verify = try decodeFixture(TokenBundle.self, "verify")
        XCTAssertFalse(verify.accessToken.isEmpty)
        XCTAssertNotNil(verify.accessExpiresAt)

        let refresh = try decodeFixture(TokenBundle.self, "refresh")
        XCTAssertFalse(refresh.refreshToken.isEmpty)

        let me = try decodeFixture(MobileMeResponse.self, "me")
        XCTAssertFalse(me.userId.isEmpty)
        XCTAssertNotNil(me.emailVerifiedAt)
        XCTAssertNotNil(me.createdAt)
        let pets = try decodeFixture(PetListResponse.self, "pets")
        XCTAssertFalse(pets.pets.isEmpty)
    }

    func testPetHomeAndAssetsFixtures() throws {
        let home = try decodeFixture(PetHomeManifest.self, "pet_home")
        XCTAssertEqual(home.manifestVersion, 1)
        XCTAssertEqual(home.defaultModel.format, "glb")
        XCTAssertEqual(home.defaultModel.bytes, 46_036_096)

        let page = try decodeFixture(AssetPage.self, "assets_page")
        XCTAssertFalse(page.items.isEmpty)

        let manifest = try decodeFixture(AssetManifest.self, "asset_manifest")
        XCTAssertFalse(manifest.assetId.isEmpty)
        XCTAssertGreaterThan(manifest.bytes ?? 0, 0)
    }

    func testSocialFixtures() throws {
        let nearby = try decodeFixture(NearbyResponse.self, "nearby")
        XCTAssertFalse(nearby.items.isEmpty)
        XCTAssertNil(nearby.items[0].pet?.name) // no-pet account: name must be optional

        let discovery = try decodeFixture(DiscoveryStatus.self, "discovery_status")
        XCTAssertTrue(discovery.enabled)
        XCTAssertNotNil(discovery.grid)

        let requests = try decodeFixture(ContactRequestListResponse.self, "contact_requests_incoming")
        XCTAssertFalse(requests.items.isEmpty)
        XCTAssertEqual(requests.items[0].direction, "incoming")

        let created = try decodeFixture(ContactRequestCreated.self, "contact_request_created")
        XCTAssertEqual(created.status, "pending")
        XCTAssertNotNil(created.identifier)

        let auto = try decodeFixture(ContactRequestCreated.self, "contact_request_auto_accepted")
        XCTAssertEqual(auto.autoAccepted, true)
        XCTAssertNotNil(auto.requestId)
        XCTAssertNotNil(auto.contactId)

        let accepted = try decodeFixture(ContactActionResponse.self, "contact_accept")
        XCTAssertEqual(accepted.status, "accepted")
        XCTAssertNotNil(accepted.contactId)

        let contacts = try decodeFixture(ContactListResponse.self, "contacts")
        XCTAssertFalse(contacts.items.isEmpty)
        XCTAssertNotNil(contacts.items[0].since)

        let blocks = try decodeFixture(BlockListResponse.self, "blocks")
        XCTAssertFalse(blocks.items.isEmpty)
        XCTAssertNotNil(blocks.items[0].resolvedPublicRef)
        XCTAssertNotNil(blocks.items[0].createdAtDate)
        let noBlocks = try decodeFixture(BlockListResponse.self, "blocks_after_remove")
        XCTAssertTrue(noBlocks.items.isEmpty)
    }

    func testMessagePaginationFixtures() throws {
        let first = try decodeFixture(MessagePage.self, "messages_page1")
        XCTAssertFalse(first.items.isEmpty)
        XCTAssertNotNil(first.nextBefore)
        XCTAssertNotNil(first.nextBeforeId)
        XCTAssertTrue(first.hasMore)

        let second = try decodeFixture(MessagePage.self, "messages_page2")
        XCTAssertFalse(second.items.isEmpty)
        XCTAssertFalse(second.items[0].body.isEmpty)
    }
}
