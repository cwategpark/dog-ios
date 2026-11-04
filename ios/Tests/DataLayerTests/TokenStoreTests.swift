import Foundation
import XCTest
@testable import DogiosDataLayer

final class TokenStoreTests: DataLayerTestCase {
    func testInMemoryStoreSaveLoadClear() throws {
        let store = InMemoryTokenStore()
        XCTAssertNil(store.load())

        let bundle = makeTokenBundle(access: "a1", refresh: "r1")
        try store.save(bundle)
        XCTAssertEqual(store.load(), bundle)
        XCTAssertEqual(store.currentAccessToken, "a1")

        try store.save(makeTokenBundle(access: "a2", refresh: "r2"))
        XCTAssertEqual(store.load()?.accessToken, "a2")

        store.clear()
        XCTAssertNil(store.load())
    }

    func testTokenBundleRoundTripsThroughDataLayerJSON() throws {
        let bundle = makeTokenBundle(access: "a1", refresh: "r1")
        let data = try DogiosJSON.makeEncoder().encode(bundle)
        let decoded = try DogiosJSON.makeDecoder().decode(TokenBundle.self, from: data)
        XCTAssertEqual(decoded.accessToken, "a1")
        XCTAssertEqual(decoded.refreshToken, "r1")
        XCTAssertEqual(decoded.userId, "user-1")
    }

    func testKeychainStoreIsConfigurable() {
        // 不在单测里读写真实钥匙串，只验证 service/account 可注入（便于隔离）。
        let store = KeychainTokenStore(service: "app.pawly.test", account: "test.tokens")
        XCTAssertEqual(store.service, "app.pawly.test")
        XCTAssertEqual(store.account, "test.tokens")
    }

    func testAccessTokenExpiry() {
        let bundle = TokenBundle(accessToken: "a",
                                 refreshToken: "r",
                                 accessExpiresAt: Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(bundle.isAccessTokenExpired(now: Date(timeIntervalSince1970: 2_000)))
        XCTAssertFalse(bundle.isAccessTokenExpired(now: Date(timeIntervalSince1970: 500)))

        let noExpiry = TokenBundle(accessToken: "a", refreshToken: "r")
        XCTAssertFalse(noExpiry.isAccessTokenExpired(now: Date()))
    }
}

final class ContactAndMessageServiceTests: DataLayerTestCase {
    func testRequestContactSendsTargetRefAndMessage() async throws {
        let (client, _) = try makeClient(accessToken: "at-1")
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/mobile/v1/contacts/requests")
            XCTAssertEqual(request.httpBodyJSON?["target_public_ref"] as? String, "pub-2")
            XCTAssertEqual(request.httpBodyJSON?["message"] as? String, "你好")
            return .json(#"{"request_id": "req-1", "status": "pending", "created_at": "2026-11-04T03:33:21Z"}"#)
        }
        let created = try await ContactService(client: client)
            .requestContact(targetPublicRef: "pub-2", message: "你好")
        XCTAssertEqual(created.requestId, "req-1")
        XCTAssertEqual(created.status, "pending")
    }

    func testIncomingRequestsQuery() async throws {
        let (client, _) = try makeClient(accessToken: "at-1")
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/mobile/v1/contacts/requests")
            XCTAssertEqual(request.queryValue("direction"), "incoming")
            return .json(#"{"items": []}"#)
        }
        let list = try await ContactService(client: client).requests(direction: .incoming)
        XCTAssertTrue(list.items.isEmpty)
    }

    func testAcceptAndContacts() async throws {
        let (client, _) = try makeClient(accessToken: "at-1")
        StubURLProtocol.setHandler { request in
            if request.url?.path == "/mobile/v1/contacts/requests/req-1/accept" {
                return .json(#"{"contact_id": "c-1", "status": "accepted"}"#)
            }
            if request.url?.path == "/mobile/v1/contacts" {
                return .json(#"{"items": []}"#)
            }
            return .json(#"{"detail": "NOT_FOUND"}"#, status: 404)
        }
        let service = ContactService(client: client)
        let accepted = try await service.accept(requestId: "req-1")
        XCTAssertEqual(accepted.contactId, "c-1")
        let contacts = try await service.contacts()
        XCTAssertTrue(contacts.items.isEmpty)
    }

    func testBlockAndUnblock() async throws {
        let (client, _) = try makeClient(accessToken: "at-1")
        StubURLProtocol.setHandler { request in
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.url?.path, "/mobile/v1/blocks")
                XCTAssertEqual(request.httpBodyJSON?["target_public_ref"] as? String, "pub-2")
            } else if request.httpMethod == "DELETE" {
                XCTAssertEqual(request.url?.path, "/mobile/v1/blocks/pub-2")
            } else {
                return .json(#"{"items": [{"target_public_ref": "pub-2"}]}"#)
            }
            return StubURLProtocol.StubResponse(status: 204)
        }
        let service = ContactService(client: client)
        try await service.block(publicRef: "pub-2")
        let blocks = try await service.blocks()
        XCTAssertEqual(blocks.items.first?.resolvedPublicRef, "pub-2")
        try await service.unblock(publicRef: "pub-2")
    }

    func testMessageSendIsIdempotentWithClientId() async throws {
        let (client, _) = try makeClient(accessToken: "at-1")
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/mobile/v1/messages")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.httpBodyJSON?["contact_id"] as? String, "c-1")
            XCTAssertEqual(request.httpBodyJSON?["client_id"] as? String, "stable-client-id")
            return .json("""
            {"message_id": "m-1", "contact_id": "c-1", "body": "hi",
             "client_id": "stable-client-id", "created_at": "2026-11-04T03:33:21Z"}
            """)
        }
        let message = try await MessageService(client: client)
            .send(contactId: "c-1", body: "hi", clientId: "stable-client-id")
        XCTAssertEqual(message.messageId, "m-1")
        XCTAssertEqual(message.clientId, "stable-client-id")
    }

    func testMessageBodyTooLongIsRejectedLocally() async throws {
        let (client, _) = try makeClient(accessToken: "at-1")
        StubURLProtocol.setHandler { _ in
            XCTFail("超长消息不应发请求")
            return .json("{}")
        }
        let service = MessageService(client: client)
        do {
            _ = try await service.send(contactId: "c-1", body: String(repeating: "a", count: 2001))
            XCTFail("应抛校验错误")
        } catch let error as MobileAPIError {
            XCTAssertEqual(error.kind, .validation)
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testMessagesPaginationQuery() async throws {
        let (client, _) = try makeClient(accessToken: "at-1")
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/mobile/v1/messages")
            XCTAssertEqual(request.queryValue("contact_id"), "c-1")
            // 真实后端游标是 Unix 秒数字；第二页同时带 before 与 before_id。
            XCTAssertEqual(request.queryValue("before"), "1793764692.624539")
            XCTAssertEqual(request.queryValue("before_id"), "m-boundary")
            XCTAssertEqual(request.queryValue("limit"), "50")
            return .json("""
            {"items": [{"message_id": "m-1", "body": "older", "sender": "them",
                        "created_at": 1793764692.622012}],
             "next_before": 1793764692.622012, "next_before_id": "m-1"}
            """)
        }
        let page = try await MessageService(client: client)
            .messages(contactId: "c-1", before: 1793764692.624539, beforeId: "m-boundary", limit: 50)
        XCTAssertEqual(page.items.first?.isFromMe, false)
        XCTAssertEqual(page.nextBefore, 1793764692.622012)
        XCTAssertEqual(page.nextBeforeId, "m-1")
        XCTAssertTrue(page.hasMore)
    }
}
