import Foundation

/// 资产（照片 / 试穿 / 模型等）分页与私有下载。
///
/// 关键边界：`GET /mobile/v1/assets/{asset_id}/download` 需要 Bearer；
/// 数据层直接返回 `Data`，绝不把私有下载路径当公开链接分发或缓存。
public final class AssetService: @unchecked Sendable {
    private let client: MobileAPIClient

    public init(client: MobileAPIClient) {
        self.client = client
    }

    /// GET `/mobile/v1/assets?kind=&cursor=&limit=`（游标不透明）。
    public func list(kind: String? = nil,
                     cursor: String? = nil,
                     limit: Int? = nil) async throws -> AssetPage {
        var query: [URLQueryItem] = []
        if let kind, !kind.isEmpty {
            query.append(URLQueryItem(name: "kind", value: kind))
        }
        if let cursor, !cursor.isEmpty {
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        if let limit {
            query.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        return try await client.send(.get("/mobile/v1/assets", query: query), as: AssetPage.self)
    }

    /// 需要认证的私有资产下载。非本人服务端返回 404（映射为 `MobileAPIError.notFound`）。
    public func download(assetId: String) async throws -> Data {
        let path = "/mobile/v1/assets/\(AssetService.pathSegment(assetId))/download"
        return try await client.download(.get(path))
    }

    /// GET `/mobile/v1/assets/{asset_id}/manifest`。
    public func manifest(assetId: String) async throws -> AssetManifest {
        let path = "/mobile/v1/assets/\(AssetService.pathSegment(assetId))/manifest"
        return try await client.send(.get(path), as: AssetManifest.self)
    }

    /// 便捷方法：按列表条目取字节（始终走认证下载，不复用 `download_url` 当公开地址）。
    public func data(for item: AssetItem) async throws -> Data {
        try await download(assetId: item.assetId)
    }

    /// 路径段百分号编码（避免 asset_id 注入额外路径）。
    static func pathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#;")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
