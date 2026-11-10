import Foundation

/// Public social profile returned by `GET/PATCH /mobile/v1/social-profile`.
///
/// The display name is a public nickname, not a legal name. `avatar.public_key` is a
/// controlled key (`default:paw` or `social:<sha256>`); it is never a private media path.
public struct SocialProfile: Codable, Equatable, Sendable {
    public let userId: String
    public let displayName: String?
    public let avatar: SocialAvatar
    public let profileCompleted: Bool
    public let missing: [String]
    public let defaultAvatarKeys: [String]
    public let limits: SocialProfileLimits?
    public let updatedAt: Date?

    public init(userId: String,
                displayName: String? = nil,
                avatar: SocialAvatar = SocialAvatar(),
                profileCompleted: Bool = false,
                missing: [String] = [],
                defaultAvatarKeys: [String] = ["paw", "dog", "cat", "leaf"],
                limits: SocialProfileLimits? = nil,
                updatedAt: Date? = nil) {
        self.userId = userId
        self.displayName = displayName
        self.avatar = avatar
        self.profileCompleted = profileCompleted
        self.missing = missing
        self.defaultAvatarKeys = defaultAvatarKeys
        self.limits = limits
        self.updatedAt = updatedAt
    }

    public var hasDisplayName: Bool { !(displayName ?? "").isEmpty }
    public var hasAvatar: Bool { avatar.available && avatar.kind != "none" }
}

public struct SocialAvatar: Codable, Equatable, Sendable {
    /// `none` | `default` | `upload`
    public let kind: String
    public let defaultKey: String?
    /// Controlled public key; never a filesystem/private path.
    public let publicKey: String?
    public let available: Bool
    public let updatedAt: Date?

    public init(kind: String = "none",
                defaultKey: String? = nil,
                publicKey: String? = nil,
                available: Bool = false,
                updatedAt: Date? = nil) {
        self.kind = kind
        self.defaultKey = defaultKey
        self.publicKey = publicKey
        self.available = available
        self.updatedAt = updatedAt
    }

    public var isDefault: Bool { kind == "default" }
    public var isUpload: Bool { kind == "upload" }
}

public struct SocialProfileLimits: Codable, Equatable, Sendable {
    public let displayNameMax: Int?
    public let avatarMaxBytes: Int?
    public let avatarMimeTypes: [String]?
    public let avatarEdge: Int?

    public init(displayNameMax: Int? = nil,
                avatarMaxBytes: Int? = nil,
                avatarMimeTypes: [String]? = nil,
                avatarEdge: Int? = nil) {
        self.displayNameMax = displayNameMax
        self.avatarMaxBytes = avatarMaxBytes
        self.avatarMimeTypes = avatarMimeTypes
        self.avatarEdge = avatarEdge
    }
}

/// `PATCH /mobile/v1/social-profile` body. Both fields are optional; at least one must be
/// present (server enforces 422).
public struct SocialProfilePatch: Encodable, Equatable, Sendable {
    public let displayName: String?
    public let defaultAvatarKey: String?

    public init(displayName: String? = nil, defaultAvatarKey: String? = nil) {
        self.displayName = displayName
        self.defaultAvatarKey = defaultAvatarKey
    }
}

/// Public social profile + owned avatar bytes.
///
/// The avatar bytes are intentionally fetched through the authenticated endpoint and returned
/// as `Data`; this service never turns the private path into a public URL. Server stores only a
/// 512px JPEG thumbnail and strips EXIF.
public final class SocialProfileService: @unchecked Sendable {
    private let client: MobileAPIClient

    public init(client: MobileAPIClient) {
        self.client = client
    }

    public func get() async throws -> SocialProfile {
        try await client.send(.get("/mobile/v1/social-profile"), as: SocialProfile.self)
    }

    /// Update nickname and/or explicitly choose a default avatar key.
    public func update(displayName: String? = nil,
                       defaultAvatarKey: String? = nil) async throws -> SocialProfile {
        guard displayName != nil || defaultAvatarKey != nil else {
            throw MobileAPIError.invalidResponse("至少需要修改一个社交资料字段")
        }
        let body = try client.encodeBody(SocialProfilePatch(displayName: displayName,
                                                            defaultAvatarKey: defaultAvatarKey))
        let request = APIRequest(method: "PATCH", path: "/mobile/v1/social-profile", body: body)
        return try await client.send(request, as: SocialProfile.self)
    }

    /// POST a local image (server re-encodes to 512px JPEG and strips EXIF).
    public func uploadAvatar(data: Data, contentType: String,
                             filename: String = "social-avatar") async throws -> SocialProfile {
        guard !data.isEmpty else { throw MobileAPIError.invalidResponse("头像文件为空") }
        guard data.count <= 5 * 1024 * 1024 else {
            throw MobileAPIError.invalidResponse("头像不能超过 5 MB")
        }
        let normalized = contentType.lowercased()
        guard ["image/jpeg", "image/png", "image/webp"].contains(normalized) else {
            throw MobileAPIError.invalidResponse("头像仅支持 JPEG、PNG 或 WebP")
        }
        let boundary = "PawlyBoundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(normalized)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")
        let request = APIRequest(method: "POST",
                                 path: "/mobile/v1/social-profile/avatar",
                                 body: body,
                                 headers: ["Content-Type": "multipart/form-data; boundary=\(boundary)"])
        return try await client.send(request, as: SocialProfile.self)
    }

    /// Authenticated avatar bytes; only the owner can fetch. Default avatars are rendered
    /// client-side from `avatar.defaultKey`, so this returns 404 for a default selection.
    public func avatarData() async throws -> Data {
        try await client.download(.get("/mobile/v1/social-profile/avatar"))
    }

    /// Controlled avatar resolver for another user's public_ref. The server independently
    /// verifies accepted-contact or mutual-discovery visibility and rejects user_id/public_key
    /// traversal; the client never constructs a private media path.
    public func avatarData(publicRef: String) async throws -> Data {
        let path = "/mobile/v1/users/\(AssetService.pathSegment(publicRef))/avatar"
        return try await client.download(.get(path))
    }

    /// Local SF Symbol mapping for explicit default avatar keys. No new image assets are
    /// introduced; this keeps the default-avatar contract client-rendered.
    public static func defaultAvatarSymbol(for key: String) -> String {
        switch key {
        case "dog": return "dog.fill"
        case "cat": return "cat.fill"
        case "leaf": return "leaf.fill"
        default: return "pawprint.fill"
        }
    }
}
