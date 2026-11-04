import Foundation
import XCTest
@testable import DogiosDataLayer

final class IdentityServiceTests: DataLayerTestCase {
    func testStartNormalizesEmailAndPurpose() async throws {
        let (client, store) = try makeClient(accessToken: nil, refreshToken: nil)
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/mobile/v1/auth/email/start")
            XCTAssertNil(request.authorizationHeader)
            let body = request.httpBodyJSON
            XCTAssertEqual(body?["email"] as? String, "a@b.com")
            XCTAssertEqual(body?["purpose"] as? String, "login")
            return .json("""
            {"challenge_id": "ch-1", "purpose": "login", "email_masked": "a***@b.com",
             "expires_at": "2026-11-04T03:43:21Z", "cooldown_seconds": 60,
             "delivery": "outbox", "dev_code": "123456"}
            """)
        }
        let service = IdentityService(client: client)
        let challenge = try await service.startEmailVerification(email: "  A@B.com  ")
        XCTAssertEqual(challenge.challengeId, "ch-1")
        XCTAssertEqual(challenge.emailPurpose, .login)
        XCTAssertEqual(challenge.delivery, "outbox")
        XCTAssertNil(store.load(), "start 阶段不应写入 token")
    }

    func testVerifyStoresTokenBundle() async throws {
        let (client, store) = try makeClient(accessToken: nil, refreshToken: nil)
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/mobile/v1/auth/email/verify")
            let body = request.httpBodyJSON
            XCTAssertEqual(body?["challenge_id"] as? String, "ch-1")
            XCTAssertEqual(body?["code"] as? String, "123456")
            return .json("""
            {"user_id": "u1", "email": "a@b.com",
             "email_verified_at": "2026-11-04T03:33:21Z",
             "access_token": "at-1", "refresh_token": "rt-1",
             "access_expires_at": "2026-11-04T03:48:21Z",
             "refresh_expires_at": "2026-12-04T03:33:21Z",
             "claimed_session_ids": ["s1"]}
            """)
        }
        let service = IdentityService(client: client)
        let bundle = try await service.verifyEmail(challengeId: "ch-1", code: " 123456 ")
        XCTAssertEqual(bundle.accessToken, "at-1")
        XCTAssertEqual(store.load()?.accessToken, "at-1")
        XCTAssertEqual(store.load()?.refreshToken, "rt-1")
        XCTAssertTrue(service.isAuthenticated)
    }

    func testMe() async throws {
        let (client, _) = try makeClient(accessToken: "at-1")
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/mobile/v1/me")
            XCTAssertEqual(request.authorizationHeader, "Bearer at-1")
            return .json(#"{"user_id": "u1", "email": "a@b.com", "pets": []}"#)
        }
        let me = try await IdentityService(client: client).me()
        XCTAssertEqual(me.userId, "u1")
    }

    func testRefreshRotatesTokens() async throws {
        let (client, store) = try makeClient(accessToken: "at-old", refreshToken: "rt-old")
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/mobile/v1/auth/refresh")
            XCTAssertEqual(request.httpBodyJSON?["refresh_token"] as? String, "rt-old")
            return .json(#"{"access_token": "at-new", "refresh_token": "rt-new"}"#)
        }
        let bundle = try await IdentityService(client: client).refresh()
        XCTAssertEqual(bundle.accessToken, "at-new")
        XCTAssertEqual(store.load()?.refreshToken, "rt-new")
    }

    func testLogoutRevokesAndClearsLocalTokens() async throws {
        let (client, store) = try makeClient(accessToken: "at-1", refreshToken: "rt-1")
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/mobile/v1/auth/logout")
            XCTAssertEqual(request.authorizationHeader, "Bearer at-1")
            XCTAssertEqual(request.httpBodyJSON?["refresh_token"] as? String, "rt-1")
            return StubURLProtocol.StubResponse(status: 204)
        }
        try await IdentityService(client: client).logout()
        XCTAssertNil(store.load())
    }

    func testLogoutClearsTokensEvenWhenServerFails() async throws {
        let (client, store) = try makeClient(accessToken: "at-1", refreshToken: "rt-1")
        StubURLProtocol.setHandler { _ in
            .json(#"{"detail": "UNAVAILABLE"}"#, status: 503)
        }
        do {
            try await IdentityService(client: client).logout()
            XCTFail("应抛出服务端错误")
        } catch let error as MobileAPIError {
            XCTAssertEqual(error.kind, .unavailable)
        }
        XCTAssertNil(store.load(), "登出失败也必须清本地 token")
    }

    func testEmailNormalization() {
        XCTAssertEqual(IdentityService.normalizedEmail("  A@B.com "), "a@b.com")
        // 契约：不做 Gmail 点号 / +tag 归一。
        XCTAssertEqual(IdentityService.normalizedEmail("a.b+tag@Gmail.com"), "a.b+tag@gmail.com")
    }
}
