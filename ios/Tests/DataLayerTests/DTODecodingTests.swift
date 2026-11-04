import Foundation
import XCTest
@testable import DogiosDataLayer

final class DTODecodingTests: DataLayerTestCase {
    private let decoder = DogiosJSON.makeDecoder()

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(type, from: Data(json.utf8))
    }

    // MARK: 通用

    func testISO8601FractionalAndOffset() throws {
        let withFraction = try XCTUnwrap(DogiosISO8601.date(from: "2026-11-04T03:33:21.123456Z"))
        let milliseconds = Int((withFraction.timeIntervalSince1970 * 1000).rounded()) % 1000
        XCTAssertEqual(milliseconds, 123)

        let zulu = try XCTUnwrap(DogiosISO8601.date(from: "2026-11-04T03:33:21Z"))
        let offset = try XCTUnwrap(DogiosISO8601.date(from: "2026-11-04T11:33:21+08:00"))
        XCTAssertEqual(zulu.timeIntervalSince1970, offset.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(DogiosISO8601.date(from: "not-a-date"))
    }

    // MARK: /me

    func testMeResponseDecodesWithUnknownFieldsAndNullAvatar() throws {
        let json = """
        {
          "user_id": "user-1",
          "public_ref": "pub-1",
          "email": "A@B.com",
          "full_name": null,
          "email_verified_at": "2026-11-04T03:33:21Z",
          "created_at": "2026-10-01T00:00:00.123456Z",
          "pets": [
            {"pet_id": "pet-1", "name": "Milo", "species": "dog", "breed": null,
             "age_months": 18, "avatar_url": null},
            {"pet_id": "pet-2", "name": "Luna"}
          ],
          "brand_new_field": {"nested": [1, 2, 3]}
        }
        """
        let me = try decode(MobileMeResponse.self, json)
        XCTAssertEqual(me.userId, "user-1")
        XCTAssertEqual(me.publicRef, "pub-1")
        XCTAssertEqual(me.fullName, nil)
        XCTAssertNotNil(me.emailVerifiedAt)
        XCTAssertEqual(me.pets.count, 2)
        XCTAssertEqual(me.pets[0].petId, "pet-1")
        XCTAssertEqual(me.pets[0].ageMonths, 18)
        XCTAssertNil(me.pets[0].avatarUrl)
        XCTAssertEqual(me.pets[1].name, "Luna")
        XCTAssertNil(me.pets[1].species)
    }

    /// 真实后端：时间字段是 Unix 秒数字；网站问卷没有名字时 `pets[].name` 是 null。
    /// 回归：此前 PetSummary.name 必填 String，导致 /me 与 /pets 整体解码失败。
    func testMeAndPetsDecodeRealBackendNumericTimesAndNullPetName() throws {
        let json = """
        {
          "user_id": "a10729a1e6e44556b554c1a496f8676e",
          "public_ref": "ef3588cba1a04be7b10a17e789431892",
          "email": "live-a@dogios.test",
          "full_name": "A Dog",
          "email_verified_at": 1793764813.298636,
          "created_at": 1793764813.160377,
          "pets": [
            {"pet_id": "a35633f64f7747c68423c1fbb1072ce6", "name": null,
             "species": "dog", "breed": null, "age_months": 24,
             "dog_size": "medium", "avatar_url": null}
          ]
        }
        """
        let me = try decode(MobileMeResponse.self, json)
        XCTAssertNotNil(me.createdAt)
        XCTAssertNotNil(me.emailVerifiedAt)
        XCTAssertEqual(me.pets.count, 1)
        XCTAssertEqual(me.pets[0].petId, "a35633f64f7747c68423c1fbb1072ce6")
        XCTAssertNil(me.pets[0].name)
        XCTAssertEqual(me.pets[0].species, "dog")
        XCTAssertEqual(me.pets[0].ageMonths, 24)

        let pets = try decode(PetListResponse.self,
                              #"{"pets": [{"pet_id": "p-null", "name": null, "species": "cat"}]}"#)
        XCTAssertEqual(pets.pets.count, 1)
        XCTAssertNil(pets.pets[0].name)
        XCTAssertEqual(pets.pets[0].species, "cat")
    }

    // MARK: pet-home

    func testPetHomeManifestDecodesContractPayload() throws {
        let json = """
        {
          "pet_id": "pet-1",
          "manifest_version": 1,
          "selected": "default",
          "avatar_url": null,
          "default_model": {
            "role": "default", "static": true, "is_default": true,
            "format": "glb", "mime": "model/gltf-binary",
            "bytes": 46036096,
            "sha256": "96efb8f20105d2280b332a13e926966c935c8e01e5ef5843be5183352283146b",
            "url": "/public-assets/website-golden-master.glb",
            "source": "website-golden-master"
          },
          "personal_model": null
        }
        """
        let manifest = try decode(PetHomeManifest.self, json)
        XCTAssertEqual(manifest.petId, "pet-1")
        XCTAssertEqual(manifest.manifestVersion, 1)
        XCTAssertEqual(manifest.selected, "default")
        XCTAssertEqual(manifest.selectedKind, .default)
        XCTAssertEqual(manifest.defaultModel.format, "glb")
        XCTAssertEqual(manifest.defaultModel.isStatic, true)
        XCTAssertEqual(manifest.defaultModel.isDefault, true)
        XCTAssertEqual(manifest.defaultModel.bytes, 46_036_096)
        XCTAssertEqual(manifest.defaultModel.url, "/public-assets/website-golden-master.glb")
        XCTAssertEqual(manifest.defaultModel.source, "website-golden-master")
        XCTAssertNil(manifest.personalModel)
    }

    func testPetHomeManifestDecodesPersonalModel() throws {
        let json = """
        {
          "pet_id": "pet-1",
          "manifest_version": 1,
          "selected": "personal",
          "default_model": {
            "format": "glb", "url": "/public-assets/website-golden-master.glb"
          },
          "personal_model": {
            "asset_id": "asset-9", "role": "personal", "static": false, "is_default": false,
            "format": "glb", "mime": "model/gltf-binary", "bytes": 1234,
            "sha256": "abc", "source_job_id": "job-7",
            "url": "/mobile/v1/assets/asset-9/download", "source": "app"
          }
        }
        """
        let manifest = try decode(PetHomeManifest.self, json)
        XCTAssertEqual(manifest.selectedKind, .personal)
        XCTAssertEqual(manifest.personalModel?.assetId, "asset-9")
        XCTAssertEqual(manifest.personalModel?.isStatic, false)
        XCTAssertEqual(manifest.personalModel?.sourceJobId, "job-7")
        XCTAssertEqual(manifest.personalModel?.url, "/mobile/v1/assets/asset-9/download")
    }

    func testUnknownSelectedValueFallsBackSafely() throws {
        let json = """
        {
          "pet_id": "pet-1", "selected": "something_new",
          "default_model": {"format": "glb", "url": "/public-assets/a.glb"}
        }
        """
        let manifest = try decode(PetHomeManifest.self, json)
        XCTAssertEqual(manifest.selected, "something_new")
        XCTAssertEqual(manifest.selectedKind, .default)
    }

    // MARK: 认证

    func testEmailChallengeDecodesOptionalFields() throws {
        let json = """
        {"challenge_id": "ch-1", "purpose": "login", "email_masked": "a***@b.com",
         "expires_at": "2026-11-04T03:43:21Z", "cooldown_seconds": 60,
         "delivery": "outbox"}
        """
        let challenge = try decode(EmailChallenge.self, json)
        XCTAssertEqual(challenge.challengeId, "ch-1")
        XCTAssertEqual(challenge.emailPurpose, .login)
        XCTAssertEqual(challenge.delivery, "outbox")
        XCTAssertEqual(challenge.cooldownSeconds, 60)
        XCTAssertNil(challenge.devCode)
    }

    func testTokenBundleDecodesAndDefaults() throws {
        let json = """
        {"user_id": "u1", "email": "a@b.com",
         "email_verified_at": "2026-11-04T03:33:21Z",
         "access_token": "at-1", "refresh_token": "rt-1",
         "access_expires_at": "2026-11-04T03:48:21Z",
         "refresh_expires_at": "2026-12-04T03:33:21Z",
         "claimed_session_ids": ["s1", "s2"]}
        """
        let bundle = try decode(TokenBundle.self, json)
        XCTAssertEqual(bundle.accessToken, "at-1")
        XCTAssertEqual(bundle.refreshToken, "rt-1")
        XCTAssertEqual(bundle.claimedSessions, ["s1", "s2"])
        XCTAssertFalse(bundle.isAccessTokenExpired(now: Date(timeIntervalSince1970: 0)))

        // 刷新响应可能不带 user_id / claimed_session_ids。
        let refreshOnly = try decode(TokenBundle.self,
                                     #"{"access_token": "at-2", "refresh_token": "rt-2"}"#)
        XCTAssertNil(refreshOnly.userId)
        XCTAssertEqual(refreshOnly.claimedSessions, [])
    }

    // MARK: 资产 / 游标分页

    func testAssetPageParsesCursorPagination() throws {
        let json = """
        {
          "items": [
            {"asset_id": "a-1", "kind": "photo", "format": "jpg", "mime": "image/jpeg",
             "bytes": 1024, "sha256": "h1", "source_job_id": null,
             "created_at": "2026-11-04T03:33:21Z",
             "download_url": "/mobile/v1/assets/a-1/download"}
          ],
          "next_cursor": "cursor-2"
        }
        """
        let page = try decode(AssetPage.self, json)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items[0].assetId, "a-1")
        XCTAssertEqual(page.items[0].bytes, 1024)
        XCTAssertNil(page.items[0].sourceJobId)
        XCTAssertEqual(page.nextCursor, "cursor-2")
        XCTAssertTrue(page.hasMore)

        let lastPage = try decode(AssetPage.self,
                                  #"{"items": [], "next_cursor": null}"#)
        XCTAssertNil(lastPage.nextCursor)
        XCTAssertFalse(lastPage.hasMore)

        // 可选字段缺失时也能安全解码。
        let minimal = try decode(AssetPage.self, #"{"items": [{"asset_id": "a-2"}]}"#)
        XCTAssertEqual(minimal.items[0].assetId, "a-2")
        XCTAssertNil(minimal.items[0].kind)
        XCTAssertNil(minimal.items[0].createdAt)
        XCTAssertFalse(minimal.hasMore)
    }

    func testAssetManifestDecodesAvailability() throws {
        let json = """
        {"asset_id": "a-1", "format": "glb", "mime": "model/gltf-binary",
         "bytes": 46036096, "sha256": "h1", "source_job_id": "job-1", "available": true}
        """
        let manifest = try decode(AssetManifest.self, json)
        XCTAssertEqual(manifest.assetId, "a-1")
        XCTAssertTrue(manifest.isAvailable)
        XCTAssertEqual(manifest.sourceJobId, "job-1")
    }

    // MARK: 发现 / 附近

    func testNearbyResponseDecodesCoarseRegion() throws {
        let json = """
        {
          "items": [
            {"public_ref": "pub-2",
             "pet": {"name": "Luna", "species": "cat", "breed": null, "age_months": 30,
                     "avatar_url": "https://cdn.example.test/luna.jpg"},
             "coarse_region": {"grid": "63:31", "label": "上海 · 静安"},
             "distance_bucket": "1_3km"}
          ],
          "radius_km": 5,
          "generated_at": "2026-11-04T03:33:21Z"
        }
        """
        let nearby = try decode(NearbyResponse.self, json)
        XCTAssertEqual(nearby.items.count, 1)
        XCTAssertEqual(nearby.items[0].publicRef, "pub-2")
        XCTAssertEqual(nearby.items[0].coarseRegion?.grid, "63:31")
        XCTAssertEqual(nearby.items[0].coarseRegion?.label, "上海 · 静安")
        XCTAssertEqual(nearby.items[0].distanceBucket, "1_3km")
        XCTAssertEqual(nearby.items[0].pet?.name, "Luna")
        XCTAssertEqual(nearby.radiusKm, 5)
        XCTAssertNotNil(nearby.generatedAt)
    }

    func testDiscoveryStatusDecodes() throws {
        let json = """
        {"enabled": true, "grid": "63:31", "expires_at": "2026-11-05T03:33:21Z", "radius_km": 5}
        """
        let status = try decode(DiscoveryStatus.self, json)
        XCTAssertTrue(status.enabled)
        XCTAssertEqual(status.grid, "63:31")
        XCTAssertEqual(status.radiusKm, 5)
        XCTAssertNotNil(status.expiresAt)
    }

    // MARK: 联系 / 消息 / 拉黑

    func testContactDtosDecode() throws {
        let requestJson = """
        {"request_id": "req-1", "status": "pending", "created_at": "2026-11-04T03:33:21Z"}
        """
        let created = try decode(ContactRequestCreated.self, requestJson)
        XCTAssertEqual(created.requestId, "req-1")
        XCTAssertEqual(created.status, "pending")

        let listJson = """
        {"items": [
          {"request_id": "req-1", "direction": "incoming", "user_public_ref": "pub-2",
           "pet": {"name": "Luna"}, "status": "pending",
           "created_at": "2026-11-04T03:33:21Z"}
        ]}
        """
        let list = try decode(ContactRequestListResponse.self, listJson)
        XCTAssertEqual(list.items.first?.direction, "incoming")
        XCTAssertEqual(list.items.first?.userPublicRef, "pub-2")
        XCTAssertEqual(list.items.first?.pet?.name, "Luna")

        let contacts = try decode(ContactListResponse.self,
                                  #"{"items": [{"contact_id": "c-1", "user_public_ref": "pub-2", "pet": {"name": "Luna"}, "since": "2026-11-04T03:33:21Z"}]}"#)
        XCTAssertEqual(contacts.items.first?.contactId, "c-1")
        XCTAssertNotNil(contacts.items.first?.since)
    }

    func testChatMessageAndMessagePageDecode() throws {
        // 真实后端：created_at / next_before 是 Unix 秒数字，并新增 next_before_id。
        let pageJson = """
        {"items": [
          {"message_id": "m-1", "contact_id": "c-1", "body": "hi", "client_id": "cid-1",
           "sender": "me", "created_at": 1793764692.6267142}
        ], "next_before": 1793764692.624539, "next_before_id": "m-0"}
        """
        let page = try decode(MessagePage.self, pageJson)
        XCTAssertEqual(page.items.first?.messageId, "m-1")
        XCTAssertEqual(page.items.first?.isFromMe, true)
        XCTAssertEqual(page.items.first?.clientId, "cid-1")
        XCTAssertEqual(page.nextBefore, 1793764692.624539)
        XCTAssertEqual(page.nextBeforeId, "m-0")
        XCTAssertTrue(page.hasMore)

        // 兼容：只有 next_before 时也能翻页；字符串数字/ISO 字符串时间仍可解码。
        let legacy = try decode(MessagePage.self, """
        {"items": [{"message_id": "m-2", "body": "x", "created_at": "2026-11-04T03:33:21Z"}],
         "next_before": "1793764692.624539"}
        """)
        XCTAssertEqual(legacy.nextBefore, 1793764692.624539)
        XCTAssertNil(legacy.nextBeforeId)

        // 最后一页：没有游标。
        let lastPage = try decode(MessagePage.self, #"{"items": [], "next_before": null}"#)
        XCTAssertNil(lastPage.nextBefore)
        XCTAssertNil(lastPage.nextBeforeId)
        XCTAssertFalse(lastPage.hasMore)
    }

    func testBlockItemAcceptsEitherRefField() throws {
        let a = try decode(BlockItem.self, #"{"target_public_ref": "pub-2", "blocked_at": "2026-11-04T03:33:21Z"}"#)
        XCTAssertEqual(a.resolvedPublicRef, "pub-2")
        let b = try decode(BlockItem.self, #"{"public_ref": "pub-3"}"#)
        XCTAssertEqual(b.resolvedPublicRef, "pub-3")
        // 真实后端 GET /blocks：items[{user_public_ref, created_at}]，DELETE 用该 public_ref。
        let real = try decode(BlockItem.self, #"{"user_public_ref": "pub-4", "created_at": 1793764692.6335318}"#)
        XCTAssertEqual(real.userPublicRef, "pub-4")
        XCTAssertEqual(real.resolvedPublicRef, "pub-4")
        XCTAssertNotNil(real.createdAt)
        XCTAssertNotNil(real.createdAtDate)

        let list = try decode(BlockListResponse.self,
                              #"{"items": [{"target_public_ref": "pub-4"}]}"#)
        XCTAssertEqual(list.items.count, 1)
    }

    // MARK: 编码

    func testEncoderProducesSnakeCase() throws {
        struct Payload: Encodable {
            let contactId: String
            let clientId: String
            let radiusKm: Int
        }
        let data = try DogiosJSON.makeEncoder().encode(Payload(contactId: "c-1",
                                                               clientId: "cid-1",
                                                               radiusKm: 5))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["contact_id"] as? String, "c-1")
        XCTAssertEqual(object["client_id"] as? String, "cid-1")
        XCTAssertEqual(object["radius_km"] as? Int, 5)
    }
}
