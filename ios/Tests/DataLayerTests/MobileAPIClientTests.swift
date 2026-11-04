import Foundation
import XCTest
@testable import DogiosDataLayer

final class MobileAPIClientTests: DataLayerTestCase {
    // MARK: Bearer

    func testBearerHeaderIsAddedForAuthenticatedRequests() async throws {
        let (client, _) = try makeClient(accessToken: "access-abc")
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.authorizationHeader, "Bearer access-abc")
            return .json(#"{"user_id": "u1", "pets": []}"#)
        }
        let me = try await client.send(.get("/mobile/v1/me"), as: MobileMeResponse.self)
        XCTAssertEqual(me.userId, "u1")
    }

    func testNoAuthorizationHeaderWithoutSession() async throws {
        let (client, _) = try makeClient(accessToken: nil, refreshToken: nil)
        StubURLProtocol.setHandler { request in
            XCTAssertNil(request.authorizationHeader)
            return .json(#"{"challenge_id": "ch-1"}"#)
        }
        let challenge = try await client.send(.post("/mobile/v1/auth/email/start",
                                                    body: Data("{}".utf8),
                                                    requiresAuth: false),
                                              as: EmailChallenge.self)
        XCTAssertEqual(challenge.challengeId, "ch-1")
    }

    func testNoAuthorizationHeaderForPublicEndpointEvenWithSession() async throws {
        let (client, _) = try makeClient(accessToken: "access-abc")
        StubURLProtocol.setHandler { request in
            XCTAssertNil(request.authorizationHeader)
            return .json(#"{"challenge_id": "ch-1"}"#)
        }
        let challenge = try await client.send(.post("/mobile/v1/auth/email/start",
                                                    body: Data("{}".utf8),
                                                    requiresAuth: false),
                                              as: EmailChallenge.self)
        XCTAssertEqual(challenge.challengeId, "ch-1")
    }

    // MARK: 401 → refresh 单飞 → 重试一次

    func test401RefreshesOnceThenRetriesWithNewToken() async throws {
        let refreshCount = TestCounter()
        let (client, store) = try makeClient(accessToken: "access-old", refreshToken: "refresh-old")
        StubURLProtocol.setHandler { request in
            switch request.url?.path {
            case "/mobile/v1/me":
                if request.authorizationHeader == "Bearer access-old" {
                    return .json(#"{"detail": "UNAUTHENTICATED"}"#, status: 401)
                }
                return .json(#"{"user_id": "u1", "pets": []}"#)
            case "/mobile/v1/auth/refresh":
                refreshCount.increment()
                XCTAssertNil(request.authorizationHeader, "refresh 请求不应带 Bearer")
                let body = request.httpBodyJSON
                XCTAssertEqual(body?["refresh_token"] as? String, "refresh-old")
                return .json(#"{"access_token": "access-new", "refresh_token": "refresh-new"}"#)
            default:
                return .json(#"{"detail": "NOT_FOUND"}"#, status: 404)
            }
        }

        let me = try await client.send(.get("/mobile/v1/me"), as: MobileMeResponse.self)
        XCTAssertEqual(me.userId, "u1")
        XCTAssertEqual(refreshCount.count, 1)
        XCTAssertEqual(StubURLProtocol.requests(path: "/mobile/v1/auth/refresh").count, 1)
        XCTAssertEqual(StubURLProtocol.requests(path: "/mobile/v1/me").count, 2)
        XCTAssertEqual(store.load()?.accessToken, "access-new")
        XCTAssertEqual(store.load()?.refreshToken, "refresh-new")
    }

    func testConcurrent401sShareSingleRefresh() async throws {
        let refreshCount = TestCounter()
        let (client, store) = try makeClient(accessToken: "access-old", refreshToken: "refresh-old")
        StubURLProtocol.setHandler { request in
            switch request.url?.path {
            case "/mobile/v1/me":
                if request.authorizationHeader == "Bearer access-old" {
                    Thread.sleep(forTimeInterval: 0.05)
                    return .json(#"{"detail": "UNAUTHENTICATED"}"#, status: 401)
                }
                return .json(#"{"user_id": "u1", "pets": []}"#)
            case "/mobile/v1/auth/refresh":
                refreshCount.increment()
                Thread.sleep(forTimeInterval: 0.05)
                return .json(#"{"access_token": "access-new", "refresh_token": "refresh-new"}"#)
            default:
                return .json(#"{"detail": "NOT_FOUND"}"#, status: 404)
            }
        }

        async let first = client.send(.get("/mobile/v1/me"), as: MobileMeResponse.self)
        async let second = client.send(.get("/mobile/v1/me"), as: MobileMeResponse.self)
        async let third = client.send(.get("/mobile/v1/me"), as: MobileMeResponse.self)
        let firstResult = try await first
        let secondResult = try await second
        let thirdResult = try await third

        XCTAssertEqual(firstResult.userId, "u1")
        XCTAssertEqual(secondResult.userId, "u1")
        XCTAssertEqual(thirdResult.userId, "u1")
        XCTAssertEqual(refreshCount.count, 1, "并发 401 只允许触发一次 refresh")
        XCTAssertEqual(StubURLProtocol.requests(path: "/mobile/v1/auth/refresh").count, 1)
        XCTAssertEqual(store.load()?.accessToken, "access-new")
    }

    func testRefreshFailureClearsTokensAndThrowsUnauthorized() async throws {
        let (client, store) = try makeClient(accessToken: "access-old", refreshToken: "refresh-old")
        StubURLProtocol.setHandler { request in
            if request.url?.path == "/mobile/v1/auth/refresh" {
                return .json(#"{"detail": "REFRESH_REUSED"}"#, status: 401)
            }
            return .json(#"{"detail": "UNAUTHENTICATED"}"#, status: 401)
        }

        do {
            _ = try await client.send(.get("/mobile/v1/me"), as: MobileMeResponse.self)
            XCTFail("refresh 失败应抛 unauthorized")
        } catch let error as MobileAPIError {
            XCTAssertEqual(error.kind, .unauthorized)
            XCTAssertTrue(error.isUnauthorized)
        }
        XCTAssertNil(store.load(), "refresh 失败必须清空 token")
        XCTAssertEqual(StubURLProtocol.requests(path: "/mobile/v1/auth/refresh").count, 1)
    }

    func testRetryAfterRefreshStill401ThrowsUnauthorized() async throws {
        let (client, _) = try makeClient(accessToken: "access-old", refreshToken: "refresh-old")
        StubURLProtocol.setHandler { request in
            if request.url?.path == "/mobile/v1/auth/refresh" {
                return .json(#"{"access_token": "access-new", "refresh_token": "refresh-new"}"#)
            }
            return .json(#"{"detail": "UNAUTHENTICATED"}"#, status: 401)
        }
        do {
            _ = try await client.send(.get("/mobile/v1/me"), as: MobileMeResponse.self)
            XCTFail("重试后仍 401 应抛 unauthorized")
        } catch let error as MobileAPIError {
            XCTAssertEqual(error.kind, .unauthorized)
        }
        // 只刷一次、只重试一次
        XCTAssertEqual(StubURLProtocol.requests(path: "/mobile/v1/auth/refresh").count, 1)
        XCTAssertEqual(StubURLProtocol.requests(path: "/mobile/v1/me").count, 2)
    }

    func testAuthEndpoint401DoesNotTriggerRefresh() async throws {
        let (client, _) = try makeClient(accessToken: "access-old", refreshToken: "refresh-old")
        StubURLProtocol.setHandler { _ in
            .json(#"{"detail": "OTP_INVALID"}"#, status: 401)
        }
        do {
            _ = try await client.send(.post("/mobile/v1/auth/email/verify",
                                            body: Data("{}".utf8),
                                            requiresAuth: false),
                                      as: TokenBundle.self)
            XCTFail("应抛错")
        } catch let error as MobileAPIError {
            XCTAssertEqual(error.kind, .unauthorized)
            XCTAssertEqual(error.code, "OTP_INVALID")
        }
        XCTAssertEqual(StubURLProtocol.requests(path: "/mobile/v1/auth/refresh").count, 0)
    }

    // MARK: 状态码 → 语义错误

    func testHTTPStatusMapping() async throws {
        let cases: [(Int, MobileAPIError.Kind)] = [
            (401, .unauthorized),
            (403, .forbidden),
            (404, .notFound),
            (409, .conflict),
            (410, .gone),
            (422, .validation),
            (429, .rateLimited),
            (503, .unavailable),
            (500, .server),
            (502, .server),
            (418, .client)
        ]
        for (status, expected) in cases {
            let (client, _) = try makeClient(accessToken: "token")
            StubURLProtocol.setHandler { _ in .json(#"{"detail": "CODE_\#(status)"}"#, status: status) }
            do {
                _ = try await client.send(.get("/mobile/v1/me", requiresAuth: false),
                                          as: MobileMeResponse.self)
                XCTFail("status \(status) 应抛错")
            } catch let error as MobileAPIError {
                XCTAssertEqual(error.kind, expected, "status \(status) 映射错误")
                XCTAssertEqual(error.status, status)
                XCTAssertEqual(error.code, "CODE_\(status)")
            }
        }
    }

    func testRateLimitedParsesRetryAfterHeader() async throws {
        let (client, _) = try makeClient()
        StubURLProtocol.setHandler { _ in
            .json(#"{"detail": "RATE_LIMITED"}"#, status: 429, headers: ["Retry-After": "30"])
        }
        do {
            _ = try await client.send(.get("/mobile/v1/me", requiresAuth: false), as: MobileMeResponse.self)
            XCTFail("应抛错")
        } catch let error as MobileAPIError {
            XCTAssertEqual(error.kind, .rateLimited)
            XCTAssertEqual(error.retryAfter, 30)
            XCTAssertTrue(error.retryable)
        }
    }

    func testNetworkErrorIsSeparateFromHTTPErrors() async throws {
        let (client, _) = try makeClient()
        StubURLProtocol.setHandler { _ in
            throw URLError(.notConnectedToInternet)
        }
        do {
            _ = try await client.send(.get("/mobile/v1/me", requiresAuth: false), as: MobileMeResponse.self)
            XCTFail("应抛网络错误")
        } catch let error as MobileAPIError {
            XCTAssertEqual(error.kind, .network)
            XCTAssertNil(error.status)
            XCTAssertTrue(error.retryable)
        }
    }

    func testDecodingErrorIsReported() async throws {
        let (client, _) = try makeClient()
        StubURLProtocol.setHandler { _ in
            StubURLProtocol.StubResponse(status: 200,
                                         headers: ["Content-Type": "application/json"],
                                         body: Data("not-json".utf8))
        }
        do {
            _ = try await client.send(.get("/mobile/v1/me"), as: MobileMeResponse.self)
            XCTFail("应抛解码错误")
        } catch let error as MobileAPIError {
            XCTAssertEqual(error.kind, .decoding)
        }
    }

    // MARK: URL 构造

    func testURLBuildingIncludesQuery() async throws {
        let (client, _) = try makeClient()
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/mobile/v1/pet-home")
            XCTAssertEqual(request.queryValue("pet_id"), "pet-1")
            return .json(#"""
            {"pet_id": "pet-1", "selected": "default",
             "default_model": {"format": "glb", "url": "/public-assets/a.glb"}}
            """#)
        }
        let manifest = try await client.send(.get("/mobile/v1/pet-home",
                                                  query: [URLQueryItem(name: "pet_id", value: "pet-1")]),
                                             as: PetHomeManifest.self)
        XCTAssertEqual(manifest.petId, "pet-1")
    }
}
