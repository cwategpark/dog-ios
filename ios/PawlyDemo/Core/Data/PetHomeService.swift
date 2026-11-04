import Foundation

// MARK: - 小家模型选择

/// 个人模型回退到默认模型的原因（UI 只读这个标记，不伪造「已生成」）。
public enum PetHomeFallbackReason: String, Equatable, Sendable {
    /// `selected == personal` 但清单里没有个人模型。
    case personalMissing = "personal_model_missing"
    /// 个人模型存在，但格式不是客户端支持的 `glb`。
    case unsupportedPersonalFormat = "unsupported_personal_format"
}

/// 小家实际应展示的模型。
///
/// 规则：个人模型**仅当存在且 `format == "glb"`** 才优先；否则用默认模型，
/// 并在发生回退时给出 `fallbackReason`。默认模型是网站首页金毛 GLB（公开只读）。
public enum PetHomeModelSelection: Equatable, Sendable {
    case personal(PersonalModel)
    case `default`(DefaultModel, fallbackReason: PetHomeFallbackReason?)

    public var isDefault: Bool {
        if case .default = self { return true }
        return false
    }

    public var fallbackReason: PetHomeFallbackReason? {
        if case .default(_, let reason) = self { return reason }
        return nil
    }

    /// 实际模型格式（供渲染层判断能力，不在数据层加载）。
    public var format: String {
        switch self {
        case .personal(let model): return model.format
        case .default(let model, _): return model.format
        }
    }

    /// 实际模型地址：个人模型是需 Bearer 的下载路径，默认模型是公开只读路径。
    public var remoteURLString: String {
        switch self {
        case .personal(let model): return model.url
        case .default(let model, _): return model.url
        }
    }

    /// 个人模型需要携带授权下载；默认模型可直接公开读取。
    public var requiresAuthorization: Bool {
        if case .personal = self { return true }
        return false
    }
}

/// pet-home 解析结果：原始清单 + 已按规则解析的模型选择。
public struct PetHomeResult: Equatable, Sendable {
    public let manifest: PetHomeManifest
    public let model: PetHomeModelSelection

    public init(manifest: PetHomeManifest, model: PetHomeModelSelection) {
        self.manifest = manifest
        self.model = model
    }
}

// MARK: - PetHomeService

/// 宠物主页：清单获取 + personal/default 选择规则。
public final class PetHomeService: @unchecked Sendable {
    private let client: MobileAPIClient

    public init(client: MobileAPIClient) {
        self.client = client
    }

    /// GET `/mobile/v1/pets`。
    public func pets() async throws -> PetListResponse {
        try await client.send(.get("/mobile/v1/pets"), as: PetListResponse.self)
    }

    /// GET `/mobile/v1/pet-home?pet_id=...`，并按 personal/default 规则解析。
    /// `petId == nil` 时后端返回该用户最新/default 清单（响应里的 `pet_id` 可为 null）。
    public func petHome(petId: String? = nil) async throws -> PetHomeResult {
        let query: [URLQueryItem] = petId.map { [URLQueryItem(name: "pet_id", value: $0)] } ?? []
        let manifest = try await client.send(.get("/mobile/v1/pet-home", query: query),
                                             as: PetHomeManifest.self)
        return PetHomeResult(manifest: manifest, model: PetHomeService.resolve(manifest))
    }

    /// 纯函数：清单 → 实际模型选择（便于无网络单测）。
    public static func resolve(_ manifest: PetHomeManifest) -> PetHomeModelSelection {
        if let personal = manifest.personalModel {
            let isGLB = personal.format.lowercased() == "glb"
            if isGLB, !personal.url.isEmpty {
                return .personal(personal)
            }
            return .default(manifest.defaultModel, fallbackReason: .unsupportedPersonalFormat)
        }
        if manifest.selectedKind == .personal {
            // 服务端声称选中个人模型，但清单没给可用个人模型 → 回退并标记原因。
            return .default(manifest.defaultModel, fallbackReason: .personalMissing)
        }
        return .default(manifest.defaultModel, fallbackReason: nil)
    }
}
