import Foundation

/// 账号模型注册表条目：`GET /mobile/v1/models`。
///
/// `asset_id` 是注册表标识；实际模型字节必须使用 `archive_asset_id` 走现有的私有资产
/// 下载端点。`download_url` 只保留为服务端展示字段，不能用来绕过 archive 标识。
public struct PrivateModel: Decodable, Equatable, Sendable, Identifiable {
    public let assetId: String
    public let archiveAssetId: String
    public let petId: String
    public let name: String
    public let revision: String?
    public let visibility: String?
    public let status: String
    public let mimeType: String?
    public let sha256: String?
    public let sizeBytes: Int64?
    public let downloadUrl: String?
    public let createdAt: Date?
    /// Free-form server source; includes `text-generated` and future values.
    public let source: String?
    public let isReferenceModel: Bool?
    public let breedSlug: String?

    public init(assetId: String,
                archiveAssetId: String,
                petId: String,
                name: String,
                revision: String? = nil,
                visibility: String? = nil,
                status: String = "unknown",
                mimeType: String? = nil,
                sha256: String? = nil,
                sizeBytes: Int64? = nil,
                downloadUrl: String? = nil,
                createdAt: Date? = nil,
                source: String? = nil,
                isReferenceModel: Bool? = nil,
                breedSlug: String? = nil) {
        self.assetId = assetId
        self.archiveAssetId = archiveAssetId
        self.petId = petId
        self.name = name
        self.revision = revision
        self.visibility = visibility
        self.status = status
        self.mimeType = mimeType
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.downloadUrl = downloadUrl
        self.createdAt = createdAt
        self.source = source
        self.isReferenceModel = isReferenceModel
        self.breedSlug = breedSlug
    }

    public var id: String { assetId }

    private enum CodingKeys: String, CodingKey {
        case assetId, archiveAssetId, petId, name, revision, visibility, status
        case mimeType, sha256, sizeBytes, downloadUrl, createdAt, source
        case isReferenceModel, breedSlug
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assetId = try container.decode(String.self, forKey: .assetId)
        archiveAssetId = try container.decode(String.self, forKey: .archiveAssetId)
        petId = try container.decodeIfPresent(String.self, forKey: .petId) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        // revision may be a string or numeric on future canonical versions.
        if let text = try? container.decodeIfPresent(String.self, forKey: .revision) {
            revision = text
        } else if let number = try? container.decodeIfPresent(Int.self, forKey: .revision) {
            revision = String(number)
        } else {
            revision = nil
        }
        visibility = try container.decodeIfPresent(String.self, forKey: .visibility)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
        sizeBytes = try container.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        downloadUrl = try container.decodeIfPresent(String.self, forKey: .downloadUrl)
        createdAt = try? container.decodeIfPresent(Date.self, forKey: .createdAt)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        isReferenceModel = try container.decodeIfPresent(Bool.self, forKey: .isReferenceModel)
        breedSlug = try container.decodeIfPresent(String.self, forKey: .breedSlug)
    }
}

public struct PrivateModelsResponse: Decodable, Equatable, Sendable {
    public let items: [PrivateModel]

    public init(items: [PrivateModel] = []) {
        self.items = items
    }
}

/// 账号模型列表与私有下载。注册表 ID 与 archive ID 严格区分。
public final class PrivateModelsService: @unchecked Sendable {
    private let client: MobileAPIClient

    public init(client: MobileAPIClient) {
        self.client = client
    }

    /// GET `/mobile/v1/models`，Bearer 鉴权。
    public func list() async throws -> PrivateModelsResponse {
        try await client.send(.get("/mobile/v1/models"), as: PrivateModelsResponse.self)
    }

    /// Downloads by `archiveAssetId`, never by registry `assetId` or `downloadUrl`.
    public func download(model: PrivateModel) async throws -> Data {
        guard !model.archiveAssetId.isEmpty else {
            throw MobileAPIError.invalidResponse("模型归档标识缺失")
        }
        return try await AssetService(client: client).download(assetId: model.archiveAssetId)
    }
}
