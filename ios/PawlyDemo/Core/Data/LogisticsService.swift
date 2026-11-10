import Foundation

/// `GET /mobile/v1/orders/logistics` 的订单物流条目。
///
/// 状态字段保持为字符串，避免未来新增状态导致整页解码失败；日期也按网站契约保留
/// 原始字符串，不把未验证的格式硬编码成 `Date`。物流 URL 只暴露合法 HTTPS。
public struct LogisticsPage: Decodable, Equatable, Sendable {
    public let items: [LogisticsOrder]
    public let nextCursor: String?

    public init(items: [LogisticsOrder] = [], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }

    public var hasMore: Bool { nextCursor != nil }

    private enum CodingKeys: String, CodingKey { case items, nextCursor }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([LogisticsOrder].self, forKey: .items) ?? []
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

public struct LogisticsOrder: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let processedAt: String
    public let status: String
    public let items: [LogisticsOrderItem]
    public let shipments: [LogisticsShipment]

    public init(id: String,
                name: String,
                processedAt: String,
                status: String,
                items: [LogisticsOrderItem] = [],
                shipments: [LogisticsShipment] = []) {
        self.id = id
        self.name = name
        self.processedAt = processedAt
        self.status = status
        self.items = items
        self.shipments = shipments
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, processedAt, status, items, shipments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        processedAt = try container.decodeIfPresent(String.self, forKey: .processedAt) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        items = try container.decodeIfPresent([LogisticsOrderItem].self, forKey: .items) ?? []
        shipments = try container.decodeIfPresent([LogisticsShipment].self, forKey: .shipments) ?? []
    }
}

public struct LogisticsOrderItem: Decodable, Equatable, Sendable {
    public let title: String
    public let quantity: Int
    public let imageUrl: URL?

    public init(title: String, quantity: Int, imageUrl: URL? = nil) {
        self.title = title
        self.quantity = quantity
        self.imageUrl = imageUrl
    }

    private enum CodingKeys: String, CodingKey { case title, quantity, imageUrl }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        quantity = try container.decodeIfPresent(Int.self, forKey: .quantity) ?? 0
        imageUrl = logisticsSecureURL(try container.decodeIfPresent(String.self, forKey: .imageUrl))
    }
}

public struct LogisticsShipment: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let status: String
    public let updatedAt: String?
    public let tracking: [LogisticsTracking]

    public init(id: String,
                status: String,
                updatedAt: String? = nil,
                tracking: [LogisticsTracking] = []) {
        self.id = id
        self.status = status
        self.updatedAt = updatedAt
        self.tracking = tracking
    }

    private enum CodingKeys: String, CodingKey { case id, status, updatedAt, tracking }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        tracking = try container.decodeIfPresent([LogisticsTracking].self, forKey: .tracking) ?? []
    }
}

public struct LogisticsTracking: Decodable, Equatable, Sendable {
    public let company: String?
    public let number: String?
    /// Only an absolute HTTPS URL is exposed; HTTP/relative/credentialed URLs decode to nil.
    public let url: URL?

    public init(company: String? = nil, number: String? = nil, url: URL? = nil) {
        self.company = company
        self.number = number
        self.url = url
    }

    private enum CodingKeys: String, CodingKey { case company, number, url }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        company = try container.decodeIfPresent(String.self, forKey: .company)
        number = try container.decodeIfPresent(String.self, forKey: .number)
        url = logisticsSecureURL(try container.decodeIfPresent(String.self, forKey: .url))
    }
}

private func logisticsSecureURL(_ raw: String?) -> URL? {
    guard let raw, let value = URL(string: raw),
          value.scheme?.lowercased() == "https",
          let host = value.host, !host.isEmpty,
          value.user == nil, value.password == nil else { return nil }
    return value
}

/// 账号物流历史。只接受服务端基于 Bearer 身份返回的数据；请求不携带 email/customer_id。
public final class LogisticsService: @unchecked Sendable {
    private let client: MobileAPIClient

    public init(client: MobileAPIClient) {
        self.client = client
    }

    /// GET `/mobile/v1/orders/logistics?cursor=...`。
    public func orders(cursor: String? = nil) async throws -> LogisticsPage {
        var query: [URLQueryItem] = []
        if let cursor, !cursor.isEmpty {
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return try await client.send(.get("/mobile/v1/orders/logistics", query: query),
                                     as: LogisticsPage.self)
    }
}
