import Foundation
import XCTest

@testable import DogiosDataLayer

/// 真实后端 HTTP 联调（不使用 URLProtocol stub）。
///
/// 仅在显式提供环境变量时执行，否则 skip：
///   DOGIOS_LIVE_BASE_URL / DOGIOS_LIVE_EMAIL_A / DOGIOS_LIVE_EMAIL_B
/// A 账号由验收脚本预置为「网站问卷上传 + 邮箱 OTP 认领」后的已验证用户，含 1 个图片资产；
/// B 账号由本测试自己用邮箱 OTP 登录。
final class LiveBackendAcceptanceTests: XCTestCase {
    private var baseURL: URL!
    private var emailA: String!
    private var emailB: String!

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rawURL = environment["DOGIOS_LIVE_BASE_URL"],
              let emailA = environment["DOGIOS_LIVE_EMAIL_A"],
              let emailB = environment["DOGIOS_LIVE_EMAIL_B"] else {
            throw XCTSkip("set DOGIOS_LIVE_BASE_URL/DOGIOS_LIVE_EMAIL_A/DOGIOS_LIVE_EMAIL_B to run the live backend acceptance test")
        }
        baseURL = try XCTUnwrap(URL(string: rawURL))
        self.emailA = emailA
        self.emailB = emailB
    }

    private func makeClient() throws -> MobileAPIClient {
        let config = try AppConfig(baseURL: baseURL, googleMapsAPIKey: nil)
        return MobileAPIClient(config: config, tokenStore: InMemoryTokenStore())
    }

    private func login(email: String) async throws -> (client: MobileAPIClient, identity: IdentityService, bundle: TokenBundle) {
        let client = try makeClient()
        let identity = IdentityService(client: client)
        let challenge = try await identity.startEmailVerification(email: email)
        let code = try XCTUnwrap(challenge.devCode, "test backend must expose dev_code (expose_dev_otp=1)")
        let bundle = try await identity.verifyEmail(challengeId: challenge.challengeId, code: code)
        return (client, identity, bundle)
    }

    func testLiveEndToEndDataLayerContract() async throws {
        // 1) two real email logins, real numeric timestamps decoded from HTTP JSON
        let (clientA, identityA, bundleA) = try await login(email: emailA)
        let (clientB, identityB, bundleB) = try await login(email: emailB)
        XCTAssertFalse(bundleA.accessToken.isEmpty)
        XCTAssertNotEqual(bundleA.userId, bundleB.userId)

        let meA = try await identityA.me()
        let meB = try await identityB.me()
        XCTAssertFalse(meA.userId.isEmpty)
        XCTAssertNotNil(meA.createdAt, "created_at must decode from real Unix seconds")
        XCTAssertNotNil(meA.emailVerifiedAt)
        XCTAssertFalse(meA.pets.isEmpty, "seeded website questionnaire pet should be claimed")
        let publicRefA = try XCTUnwrap(meA.publicRef)
        let publicRefB = try XCTUnwrap(meB.publicRef)

        // 2) pet home: default website golden master (real bytes/sha256) and pets list
        let petHome = try await PetHomeService(client: clientA).petHome()
        XCTAssertEqual(petHome.manifest.selected, "default")
        XCTAssertEqual(petHome.manifest.defaultModel.format, "glb")
        XCTAssertEqual(petHome.manifest.defaultModel.bytes, 46_036_096)
        XCTAssertEqual((petHome.manifest.defaultModel.sha256 ?? "").count, 64)
        XCTAssertEqual(petHome.manifest.defaultModel.isStatic, true)
        XCTAssertNil(petHome.manifest.personalModel)

        // 3) private assets list + authenticated download (never a public link)
        let assetPage = try await AssetService(client: clientA).list(limit: 20)
        let photo = try XCTUnwrap(assetPage.items.first(where: { $0.kind == "photo" }) ?? assetPage.items.first)
        XCTAssertNotNil(photo.createdAt, "asset created_at must decode from real Unix seconds")
        let bytes = try await AssetService(client: clientA).download(assetId: photo.assetId)
        XCTAssertFalse(bytes.isEmpty)
        let manifestData = try await AssetService(client: clientA).manifest(assetId: photo.assetId)
        XCTAssertEqual(manifestData.available, true)

        // 4) discovery + nearby (coarse grid only)
        let discoveryA = try await DiscoveryService(client: clientA)
            .setDiscovery(enabled: true, coordinate: GeoCoordinate(lat: 31.23, lon: 121.47), radiusKm: 5)
        XCTAssertTrue(discoveryA.enabled)
        XCTAssertNotNil(discoveryA.grid)
        XCTAssertNotNil(discoveryA.expiresAt)
        _ = try await DiscoveryService(client: clientB)
            .setDiscovery(enabled: true, coordinate: GeoCoordinate(lat: 31.24, lon: 121.48), radiusKm: 5)
        let nearby = try await DiscoveryService(client: clientA).nearby()
        let seenB = nearby.items.first(where: { $0.publicRef == publicRefB })
        let nearbyItem = try XCTUnwrap(seenB, "A should see B in nearby")
        XCTAssertNotNil(nearbyItem.distanceBucket)
        XCTAssertNotNil(nearbyItem.coarseRegion?.grid)

        // 5) contact request -> accept -> persistent 1:1 messages with same-second pagination
        let created = try await ContactService(client: clientA)
            .requestContact(targetPublicRef: publicRefB, message: "你好，一起遛狗吗")
        XCTAssertTrue(created.requestId != nil || created.contactId != nil)
        let incoming = try await ContactService(client: clientB).requests(direction: .incoming)
        let request = try XCTUnwrap(incoming.items.first(where: { $0.userPublicRef == publicRefA }))
        let accepted = try await ContactService(client: clientB).accept(requestId: request.requestId)
        let contactId = try XCTUnwrap(accepted.contactId)
        let contacts = try await ContactService(client: clientA).contacts()
        XCTAssertTrue(contacts.items.contains(where: { $0.contactId == contactId }))
        let messageServiceA = MessageService(client: clientA)
        for index in 0..<3 {
            _ = try await messageServiceA.send(contactId: contactId, body: "live-msg-\(index)", clientId: "live-\(index)")
        }
        let messageServiceB = MessageService(client: clientB)
        let firstPage = try await messageServiceB.messages(contactId: contactId, limit: 2)
        XCTAssertEqual(firstPage.items.count, 2)
        XCTAssertNotNil(firstPage.nextBefore)
        XCTAssertNotNil(firstPage.nextBeforeId)
        let secondPage = try await messageServiceB.messages(contactId: contactId,
                                                            before: firstPage.nextBefore,
                                                            beforeId: firstPage.nextBeforeId,
                                                            limit: 2)
        let bodies = Set((firstPage.items + secondPage.items).map(\.body))
        XCTAssertEqual(bodies, ["live-msg-0", "live-msg-1", "live-msg-2"])
        XCTAssertNil(secondPage.nextBefore)

        // 6) blocks list / unblock round-trip using the decoded public ref
        try await ContactService(client: clientA).block(publicRef: publicRefB)
        let blocks = try await ContactService(client: clientA).blocks()
        let blocked = try XCTUnwrap(blocks.items.first)
        XCTAssertEqual(blocked.resolvedPublicRef, publicRefB)
        XCTAssertNotNil(blocked.createdAtDate)
        try await ContactService(client: clientA).unblock(publicRef: publicRefB)
        let blocksAfterUnblock = try await ContactService(client: clientA).blocks()
        XCTAssertTrue(blocksAfterUnblock.items.isEmpty)

        // 7) refresh rotates access; logout revokes the family and the next /me is unauthorized
        _ = try await identityA.refresh()
        let meAfterRefresh = try await identityA.me()
        XCTAssertEqual(meAfterRefresh.userId, meA.userId)
        try await identityA.logout()
        XCTAssertFalse(clientA.hasSession)
        do {
            _ = try await identityA.me()
            XCTFail("me() must fail after logout / family revocation")
        } catch let error as MobileAPIError {
            XCTAssertEqual(error.kind, .unauthorized)
        }
    }
}
