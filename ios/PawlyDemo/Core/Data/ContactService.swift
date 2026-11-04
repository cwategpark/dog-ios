import Foundation

/// 联系（好友申请 / 联系人 / 拉黑）。
///
/// 规则：先申请再聊天；同向 pending 幂等复用；被对方拉黑 403；
/// block 后双方 nearby 不可见、请求与消息均被服务端拒绝。
public final class ContactService: @unchecked Sendable {
    private let client: MobileAPIClient

    public init(client: MobileAPIClient) {
        self.client = client
    }

    /// POST `/mobile/v1/contacts/requests`（同向 pending 幂等复用）。
    public func requestContact(targetPublicRef: String,
                               message: String? = nil) async throws -> ContactRequestCreated {
        struct ContactRequestBody: Encodable {
            let targetPublicRef: String
            let message: String?
        }
        let payload = ContactRequestBody(targetPublicRef: targetPublicRef,
                                         message: message.flatMap { $0.isEmpty ? nil : $0 })
        let body = try client.encodeBody(payload)
        return try await client.send(.post("/mobile/v1/contacts/requests", body: body),
                                     as: ContactRequestCreated.self)
    }

    /// GET `/mobile/v1/contacts/requests?direction=incoming|outgoing`。
    public func requests(direction: ContactRequestDirection) async throws -> ContactRequestListResponse {
        try await client.send(.get("/mobile/v1/contacts/requests",
                                   query: [URLQueryItem(name: "direction", value: direction.rawValue)]),
                              as: ContactRequestListResponse.self)
    }

    /// POST `/mobile/v1/contacts/requests/{id}/accept`。
    public func accept(requestId: String) async throws -> ContactActionResponse {
        let path = "/mobile/v1/contacts/requests/\(AssetService.pathSegment(requestId))/accept"
        return try await client.send(.post(path), as: ContactActionResponse.self)
    }

    /// POST `/mobile/v1/contacts/requests/{id}/decline`。
    public func decline(requestId: String) async throws -> ContactActionResponse {
        let path = "/mobile/v1/contacts/requests/\(AssetService.pathSegment(requestId))/decline"
        return try await client.send(.post(path), as: ContactActionResponse.self)
    }

    /// GET `/mobile/v1/contacts`。
    public func contacts() async throws -> ContactListResponse {
        try await client.send(.get("/mobile/v1/contacts"), as: ContactListResponse.self)
    }

    /// GET `/mobile/v1/blocks`。
    public func blocks() async throws -> BlockListResponse {
        try await client.send(.get("/mobile/v1/blocks"), as: BlockListResponse.self)
    }

    /// POST `/mobile/v1/blocks`。
    public func block(publicRef: String) async throws {
        struct BlockRequest: Encodable {
            let targetPublicRef: String
        }
        let body = try client.encodeBody(BlockRequest(targetPublicRef: publicRef))
        try await client.sendNoContent(.post("/mobile/v1/blocks", body: body))
    }

    /// DELETE `/mobile/v1/blocks/{public_ref}`。
    public func unblock(publicRef: String) async throws {
        let path = "/mobile/v1/blocks/\(AssetService.pathSegment(publicRef))"
        try await client.sendNoContent(.delete(path))
    }
}

/// 联系请求方向。
public enum ContactRequestDirection: String, CaseIterable, Sendable {
    case incoming
    case outgoing
}
