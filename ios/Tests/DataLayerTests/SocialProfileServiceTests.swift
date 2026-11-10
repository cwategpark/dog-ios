import Foundation
import XCTest
@testable import DogiosDataLayer
#if canImport(DogiosDataLayer)
@testable import MobileSessionState
#endif

final class SocialProfileServiceTests: DataLayerTestCase {
    func testGetDecodesPublicFieldsAndUsesBearer() async throws {
        let (client, _) = try makeClient(accessToken: "social-token")
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/mobile/v1/social-profile")
            XCTAssertEqual(request.authorizationHeader, "Bearer social-token")
            return .json("""
            {"user_id":"u1","display_name":"小金","avatar":{"kind":"default","default_key":"paw",
             "public_key":"default:paw","available":true,"updated_at":1793764692.6},
             "profile_completed":true,"missing":[],"default_avatar_keys":["paw","dog"],
             "limits":{"display_name_max":40,"avatar_max_bytes":5242880},
             "updated_at":1793764692.6}
            """)
        }
        let profile = try await SocialProfileService(client: client).get()
        XCTAssertEqual(profile.userId, "u1")
        XCTAssertEqual(profile.displayName, "小金")
        XCTAssertEqual(profile.avatar.defaultKey, "paw")
        XCTAssertTrue(profile.avatar.isDefault)
        XCTAssertTrue(profile.profileCompleted)
        XCTAssertNotNil(profile.updatedAt)
        XCTAssertEqual(profile.limits?.displayNameMax, 40)
    }

    func testPatchSendsOnlyRequestedFieldsAndDecodesIncompleteProfile() async throws {
        let (client, _) = try makeClient(accessToken: "social-token")
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/mobile/v1/social-profile")
            XCTAssertEqual(request.httpMethod, "PATCH")
            let body = request.httpBodyJSON
            XCTAssertEqual(body?["display_name"] as? String, "小金")
            XCTAssertNil(body?["default_avatar_key"])
            return .json("""
            {"user_id":"u1","display_name":"小金","avatar":{"kind":"none","default_key":null,
             "public_key":null,"available":false,"updated_at":null},
             "profile_completed":false,"missing":["avatar"],
             "default_avatar_keys":["paw"],"limits":{"display_name_max":40}}
            """)
        }
        let profile = try await SocialProfileService(client: client)
            .update(displayName: "小金")
        XCTAssertEqual(profile.displayName, "小金")
        XCTAssertFalse(profile.profileCompleted)
        XCTAssertEqual(profile.missing, ["avatar"])
    }

    func testUploadAvatarUsesMultipartAndReturnsProfile() async throws {
        let (client, _) = try makeClient(accessToken: "social-token")
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/mobile/v1/social-profile/avatar")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue((request.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("multipart/form-data; boundary="))
            XCTAssertTrue(request.httpBodyData?.range(of: Data("name=\"file\"".utf8)) != nil)
            XCTAssertTrue(request.httpBodyData?.range(of: bytes) != nil)
            return .json("""
            {"user_id":"u1","display_name":"小金","avatar":{"kind":"upload","default_key":null,
             "public_key":"social:abc","available":true,"updated_at":1793764692.6},
             "profile_completed":true,"missing":[],"default_avatar_keys":["paw"],
             "limits":{"avatar_max_bytes":5242880}}
            """, status: 201)
        }
        let profile = try await SocialProfileService(client: client)
            .uploadAvatar(data: bytes, contentType: "image/jpeg")
        XCTAssertTrue(profile.avatar.isUpload)
        XCTAssertEqual(profile.avatar.publicKey, "social:abc")
        XCTAssertTrue(profile.profileCompleted)
    }

    func testAvatarBytesGoThroughAuthenticatedDownload() async throws {
        let (client, _) = try makeClient(accessToken: "social-token")
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/mobile/v1/social-profile/avatar")
            XCTAssertEqual(request.authorizationHeader, "Bearer social-token")
            return StubURLProtocol.StubResponse(status: 200,
                                               headers: ["Content-Type": "image/jpeg"],
                                               body: Data([1, 2, 3]))
        }
        let data = try await SocialProfileService(client: client).avatarData()
        XCTAssertEqual(data, Data([1, 2, 3]))
    }

    func testDefaultSymbolsAreClientRenderedKeys() {
        XCTAssertEqual(SocialProfileService.defaultAvatarSymbol(for: "dog"), "dog.fill")
        XCTAssertEqual(SocialProfileService.defaultAvatarSymbol(for: "cat"), "cat.fill")
        XCTAssertEqual(SocialProfileService.defaultAvatarSymbol(for: "leaf"), "leaf.fill")
        XCTAssertEqual(SocialProfileService.defaultAvatarSymbol(for: "unknown"), "pawprint.fill")
    }
}

@MainActor
final class SocialProfileStoreTests: XCTestCase {
    func testLoadProfileUnlocksSocialWhenComplete() async throws {
        let (client, _) = try makeClient(accessToken: "social-token")
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/mobile/v1/social-profile")
            return .json("""
            {"user_id":"u1","display_name":"小金","avatar":{"kind":"default","default_key":"paw",
             "public_key":"default:paw","available":true,"updated_at":null},
             "profile_completed":true,"missing":[],"default_avatar_keys":["paw"],
             "limits":{"display_name_max":40}}
            """)
        }
        let app = MobileAppStore(client: client)
        app.me = MobileMeResponse(userId: "u1")
        XCTAssertTrue(app.needsSocialProfile)
        await app.loadSocialProfile()
        XCTAssertEqual(app.socialProfile?.displayName, "小金")
        XCTAssertFalse(app.needsSocialProfile)
        XCTAssertFalse(app.socialProfileLoading)
    }

    func testIncompleteProfileStaysGated() async throws {
        let (client, _) = try makeClient(accessToken: "social-token")
        StubURLProtocol.setHandler { _ in
            .json("""
            {"user_id":"u1","display_name":null,"avatar":{"kind":"none","default_key":null,
             "public_key":null,"available":false,"updated_at":null},
             "profile_completed":false,"missing":["display_name","avatar"],
             "default_avatar_keys":["paw"],"limits":{"display_name_max":40}}
            """)
        }
        let app = MobileAppStore(client: client)
        app.me = MobileMeResponse(userId: "u1")
        await app.loadSocialProfile()
        XCTAssertFalse(app.socialProfile?.profileCompleted ?? true)
        XCTAssertTrue(app.needsSocialProfile)
    }

    func testLogoutClearsSocialProfileState() async throws {
        let (client, _) = try makeClient(accessToken: "social-token")
        StubURLProtocol.setHandler { _ in .json(#"{"user_id":"u1","pets":[]}"#) }
        let app = MobileAppStore(client: client)
        app.me = MobileMeResponse(userId: "u1")
        app.socialProfile = SocialProfile(userId: "u1", displayName: "小金",
                                          avatar: SocialAvatar(kind: "default", defaultKey: "paw",
                                                               publicKey: "default:paw", available: true),
                                          profileCompleted: true)
        await app.logout()
        XCTAssertNil(app.me)
        XCTAssertNil(app.socialProfile)
        XCTAssertNil(app.socialAvatarData)
    }
}

extension SocialProfileServiceTests {
    func testResolverUsesPublicRefPathAndBearer() async throws {
        let (client, _) = try makeClient(accessToken: "social-token")
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/mobile/v1/users/abc123/avatar")
            XCTAssertEqual(request.authorizationHeader, "Bearer social-token")
            return StubURLProtocol.StubResponse(status: 200,
                                               headers: ["Content-Type": "image/jpeg"],
                                               body: Data([9, 9]))
        }
        let data = try await SocialProfileService(client: client).avatarData(publicRef: "abc123")
        XCTAssertEqual(data, Data([9, 9]))
    }

    func testSocialFieldsAreOptionalForNearbyContactsAndRequests() throws {
        let decoder = DogiosJSON.makeDecoder()
        let nearby = try decoder.decode(NearbyResponse.self, from: Data("""
        {"items":[{"public_ref":"p1","pet":{"name":"A"},"coarse_region":{"grid":"1:2"},
          "distance_bucket":"lt_1km","social_display_name":"A家长",
          "social_avatar":{"kind":"upload","default_key":null,
            "authenticated_path":"/mobile/v1/users/p1/avatar","available":true}}]}
        """.utf8))
        XCTAssertEqual(nearby.items[0].socialDisplayName, "A家长")
        XCTAssertEqual(nearby.items[0].socialAvatar?.authenticatedPath, "/mobile/v1/users/p1/avatar")
        XCTAssertTrue(nearby.items[0].socialAvatar?.isUpload == true)

        let old = try decoder.decode(NearbyResponse.self, from: Data("""
        {"items":[{"public_ref":"p2","pet":{"name":"B"},"coarse_region":{"grid":"1:2"}}]}
        """.utf8))
        XCTAssertNil(old.items[0].socialDisplayName)
        XCTAssertNil(old.items[0].socialAvatar)

        let contacts = try decoder.decode(ContactListResponse.self, from: Data("""
        {"items":[{"contact_id":"c1","user_public_ref":"p1","social_display_name":"A家长",
          "social_avatar":{"kind":"default","default_key":"paw","available":true}}]}
        """.utf8))
        XCTAssertEqual(contacts.items[0].socialAvatar?.defaultKey, "paw")
        XCTAssertFalse(contacts.items[0].socialAvatar?.isUpload == true)

        let requests = try decoder.decode(ContactRequestListResponse.self, from: Data("""
        {"items":[{"request_id":"r1","direction":"incoming","social_display_name":null,
          "social_avatar":{"kind":"none","available":false}}]}
        """.utf8))
        XCTAssertNil(requests.items[0].socialDisplayName)
        XCTAssertEqual(requests.items[0].socialAvatar?.kind, "none")
    }
}
