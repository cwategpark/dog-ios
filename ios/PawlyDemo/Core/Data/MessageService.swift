import Foundation

/// 私聊消息。
///
/// 发送步骤（契约 §4 + 参考约定）：客户端生成 `client_id` → 服务端按
/// `(contact_id, client_id)` 幂等 → 返回持久化确认；离线重发必须复用原
/// `client_id`，因此 `send` 要求调用方传入（缺省时生成一个新的并返回在消息体里）。
public final class MessageService: @unchecked Sendable {
    /// 契约 §4：body ≤ 2000。
    public static let maxBodyLength = 2000

    private let client: MobileAPIClient

    public init(client: MobileAPIClient) {
        self.client = client
    }

    /// POST `/mobile/v1/messages`（幂等）。
    /// - Parameter clientId: 幂等键；重试/离线重发时传入同一个值。
    public func send(contactId: String,
                     body text: String,
                     clientId: String? = nil) async throws -> ChatMessage {
        guard !text.isEmpty, text.count <= MessageService.maxBodyLength else {
            throw MobileAPIError(kind: .validation,
                                 status: 422,
                                 code: "VALIDATION_ERROR",
                                 message: "消息长度需在 1...\(MessageService.maxBodyLength) 字之间")
        }
        struct SendMessageRequest: Encodable {
            let contactId: String
            let body: String
            let clientId: String
        }
        let payload = SendMessageRequest(contactId: contactId,
                                         body: text,
                                         clientId: clientId ?? UUID().uuidString)
        let data = try client.encodeBody(payload)
        return try await client.send(.post("/mobile/v1/messages", body: data), as: ChatMessage.self)
    }

    /// GET `/mobile/v1/messages?contact_id=&before=&before_id=&limit=`：按会话顺序向上翻页。
    ///
    /// 后端游标是 Unix 秒 Float（`next_before`）；新增 `next_before_id` 作为同时间戳内的
    /// 二级键。翻页时**必须同时带** `before` + `before_id`（如果有），否则同一秒内的
    /// 多条消息可能漏页/重复。
    public func messages(contactId: String,
                         before: Double? = nil,
                         beforeId: String? = nil,
                         limit: Int? = nil) async throws -> MessagePage {
        var query = [URLQueryItem(name: "contact_id", value: contactId)]
        if let before {
            // 用 Double 的最短往返表示，避免 %.6f 在微秒级产生边界漂移。
            query.append(URLQueryItem(name: "before", value: String(before)))
        }
        if let beforeId, !beforeId.isEmpty {
            query.append(URLQueryItem(name: "before_id", value: beforeId))
        }
        if let limit {
            query.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        return try await client.send(.get("/mobile/v1/messages", query: query), as: MessagePage.self)
    }
}
