import Foundation

// MARK: - JSON 编解码

/// 时间字段的兼容字符串解析。
///
/// 真实后端（FastAPI + SQLite/Postgres）所有时间字段都是 Python `time.time()` 写出的
/// **Unix 秒数字（JSON Float）**，例如 `1793764684.022371`；数据层以数字为主路径解码。
/// 本类型保留 ISO8601 字符串解析，兼容历史/网关字符串格式（旧测试、代理层可能给字符串）。
public enum DogiosISO8601 {
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    /// 解析失败返回 nil，由调用方决定降级（DTO 的日期字段一律可选）。
    public static func date(from string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let date = fractionalFormatter.date(from: trimmed) { return date }
        if let date = plainFormatter.date(from: trimmed) { return date }
        return manuallyParsedDate(from: trimmed)
    }

    /// 编码为带毫秒的 UTC ISO8601 字符串。
    public static func string(from date: Date) -> String {
        fractionalFormatter.string(from: date)
    }

    /// 兜底解析：`yyyy-MM-ddTHH:mm:ss[.fraction][Z|±HH:MM|±HHMM]`。
    private static func manuallyParsedDate(from string: String) -> Date? {
        let normalized = string.replacingOccurrences(of: " ", with: "T")
        guard let separator = normalized.firstIndex(of: "T") else { return nil }
        let datePart = String(normalized[normalized.startIndex..<separator])
        let remaining = String(normalized[normalized.index(after: separator)...])
        guard !datePart.isEmpty, !remaining.isEmpty else { return nil }

        // 时区后缀
        var timePart = remaining
        var offsetSeconds = 0
        if let utcIndex = timePart.firstIndex(where: { $0 == "Z" || $0 == "z" }) {
            timePart = String(timePart[timePart.startIndex..<utcIndex])
        } else if let signIndex = timePart.firstIndex(where: { $0 == "+" || $0 == "-" }) {
            let offsetPart = String(timePart[timePart.index(after: signIndex)...])
            timePart = String(timePart[timePart.startIndex..<signIndex])
            let sign = timePart.hasSuffix("-") ? -1 : 1
            let digits = offsetPart.replacingOccurrences(of: ":", with: "")
            guard let hours = Int(digits.prefix(2)), let minutes = Int(digits.dropFirst(2).prefix(2)) else { return nil }
            offsetSeconds = sign * (hours * 3600 + minutes * 60)
        }

        // 小数秒（纳秒整数，避免 Double 误差）
        var fractionalNanoseconds: Int64 = 0
        if let dotIndex = timePart.firstIndex(of: ".") {
            let digits = String(timePart[timePart.index(after: dotIndex)...])
            timePart = String(timePart[timePart.startIndex..<dotIndex])
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
            let padded = digits.padding(toLength: 9, withPad: "0", startingAt: 0)
            guard let nanos = Int64(padded.prefix(9)) else { return nil }
            fractionalNanoseconds = nanos
        }

        let dateComponents = datePart.split(separator: "-").compactMap { Int($0) }
        let timeComponents = timePart.split(separator: ":").compactMap { Int($0) }
        guard dateComponents.count == 3, timeComponents.count == 3 else { return nil }

        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: offsetSeconds) ?? TimeZone(secondsFromGMT: 0)
        components.year = dateComponents[0]
        components.month = dateComponents[1]
        components.day = dateComponents[2]
        components.hour = timeComponents[0]
        components.minute = timeComponents[1]
        components.second = timeComponents[2]
        guard let base = components.calendar?.date(from: components) else { return nil }
        return base.addingTimeInterval(Double(fractionalNanoseconds) / 1_000_000_000.0)
    }
}

/// 数据层统一 JSON 编解码器。
///
/// - 后端为 snake_case：解码用 `.convertFromSnakeCase`，编码用 `.convertToSnakeCase`。
/// - 时间字段：真实后端是 **Unix 秒数字（Float/Int）**；同时兼容 ISO8601 字符串，
///   见 `DogiosISO8601`。编码统一输出 ISO8601 字符串（仅用于本地 token 包等场景）。
public enum DogiosJSON {
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            // 主路径：Python time.time() → JSON number（Unix 秒）。
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            // 兼容路径：ISO8601 字符串。
            if let raw = try? container.decode(String.self),
               let date = DogiosISO8601.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "时间字段必须是 Unix 秒数字（number）或 ISO8601 字符串"
            )
        }
        return decoder
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(DogiosISO8601.string(from: date))
        }
        return encoder
    }
}

// MARK: - 认证

/// `POST /mobile/v1/auth/email/start` 的 202 响应。
public struct EmailChallenge: Codable, Equatable, Sendable {
    public let challengeId: String
    public let purpose: String?
    public let emailMasked: String?
    public let expiresAt: Date?
    public let cooldownSeconds: Int?
    /// `email` | `outbox` | `unavailable`
    public let delivery: String?
    /// 仅 development/test 且显式开启时出现；生产不得依赖。
    public let devCode: String?

    public init(challengeId: String,
                purpose: String? = nil,
                emailMasked: String? = nil,
                expiresAt: Date? = nil,
                cooldownSeconds: Int? = nil,
                delivery: String? = nil,
                devCode: String? = nil) {
        self.challengeId = challengeId
        self.purpose = purpose
        self.emailMasked = emailMasked
        self.expiresAt = expiresAt
        self.cooldownSeconds = cooldownSeconds
        self.delivery = delivery
        self.devCode = devCode
    }

    /// 后端 `purpose` 实际值：`mobile_login`（移动登录）/ `website_claim`（网站认领）；
    /// 同时兼容契约文档里的 `login` / `claim`。
    public var emailPurpose: EmailPurpose? {
        EmailPurpose(purpose: purpose)
    }
}

/// OTP 用途。`login` 只登录、不认领游客会话；`claim` 显式认领。
public enum EmailPurpose: String, Codable, CaseIterable, Sendable {
    case login
    case claim

    /// 兼容后端实际返回的 `mobile_login` / `website_claim` 与契约的 `login` / `claim`。
    public init?(purpose: String?) {
        guard let purpose else { return nil }
        switch purpose.lowercased() {
        case "login", "mobile_login":
            self = .login
        case "claim", "website_claim":
            self = .claim
        default:
            return nil
        }
    }
}

/// 短期 access token + 轮换 refresh token。`verify`/`refresh`/深链兑换共用。
public struct TokenBundle: Codable, Equatable, Sendable {
    public let userId: String?
    public let email: String?
    public let emailVerifiedAt: Date?
    public let accessToken: String
    public let refreshToken: String
    public let accessExpiresAt: Date?
    public let refreshExpiresAt: Date?
    public let claimedSessionIds: [String]?

    public init(userId: String? = nil,
                email: String? = nil,
                emailVerifiedAt: Date? = nil,
                accessToken: String,
                refreshToken: String,
                accessExpiresAt: Date? = nil,
                refreshExpiresAt: Date? = nil,
                claimedSessionIds: [String]? = nil) {
        self.userId = userId
        self.email = email
        self.emailVerifiedAt = emailVerifiedAt
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessExpiresAt = accessExpiresAt
        self.refreshExpiresAt = refreshExpiresAt
        self.claimedSessionIds = claimedSessionIds
    }

    public var claimedSessions: [String] { claimedSessionIds ?? [] }

    /// access token 是否已过期（`expiresAt` 缺失时按未过期处理）。
    public func isAccessTokenExpired(now: Date = Date()) -> Bool {
        guard let accessExpiresAt else { return false }
        return accessExpiresAt <= now
    }
}

// MARK: - 账号 / 宠物

/// `GET /mobile/v1/me`。
///
/// 注意：类型名带 `Mobile` 前缀是为了避免与仓库既有演示 UI 的
/// `PawlyDemo/Core/Models.swift` 里旧的 `MeResponse` 重名（同 target 编译）。
public struct MobileMeResponse: Codable, Equatable, Sendable {
    public let userId: String
    public let publicRef: String?
    public let email: String?
    public let fullName: String?
    public let emailVerifiedAt: Date?
    public let createdAt: Date?
    public let pets: [PetSummary]

    public init(userId: String,
                publicRef: String? = nil,
                email: String? = nil,
                fullName: String? = nil,
                emailVerifiedAt: Date? = nil,
                createdAt: Date? = nil,
                pets: [PetSummary] = []) {
        self.userId = userId
        self.publicRef = publicRef
        self.email = email
        self.fullName = fullName
        self.emailVerifiedAt = emailVerifiedAt
        self.createdAt = createdAt
        self.pets = pets
    }
}

/// Goals/avoidance can be sent as a single string (legacy simple profile) or an array.
public struct FlexibleStringList: Codable, Equatable, Sendable {
    public let values: [String]

    public init(_ values: [String] = []) { self.values = values }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            values = trimmed.isEmpty ? [] : [trimmed]
        } else {
            values = try container.decode([String].self)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

/// Canonical avoidance object: `{status: unknown|none|specified, items: [String]}`.
/// Also accepts a legacy single string or string array without losing structured status.
public struct PetAvoidance: Codable, Equatable, Sendable {
    public let status: String
    public let items: [String]

    public init(status: String = "unknown", items: [String] = []) {
        self.status = status
        self.items = items
    }

    private enum CodingKeys: String, CodingKey { case status, items }

    public init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self) {
            let rawStatus = try keyed.decodeIfPresent(String.self, forKey: .status)?.lowercased()
            let decodedItems = try keyed.decodeIfPresent([String].self, forKey: .items) ?? []
            if let rawStatus, ["unknown", "none", "specified"].contains(rawStatus) {
                status = rawStatus
            } else {
                status = decodedItems.isEmpty ? "unknown" : "specified"
            }
            items = decodedItems
            return
        }
        let single = try decoder.singleValueContainer()
        if let text = try? single.decode(String.self) {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if ["unknown", "none"].contains(normalized.lowercased()) {
                status = normalized.lowercased(); items = []
            } else {
                status = normalized.isEmpty ? "unknown" : "specified"
                items = normalized.isEmpty ? [] : [normalized]
            }
            return
        }
        if let array = try? single.decode([String].self) {
            status = array.isEmpty ? "unknown" : "specified"; items = array
            return
        }
        throw DecodingError.dataCorruptedError(in: single,
            debugDescription: "avoidance must be an object, string, or string array")
    }

    public func encode(to encoder: Encoder) throws {
        var keyed = encoder.container(keyedBy: CodingKeys.self)
        try keyed.encode(status, forKey: .status)
        try keyed.encode(items, forKey: .items)
    }

    public var isUnknown: Bool { status == "unknown" }
    public var isSpecified: Bool { status == "specified" }
}

/// `GET /me`/`GET /pets` per-pet lifetime information from the canonical new API.
/// All fields are optional so an older payload still decodes.
public struct PetInformation: Codable, Equatable, Sendable {
    public let type: String?
    public let petName: String?
    public let breed: String?
    public let dogSize: String?
    public let birthYear: Int?
    public let birthMonth: Int?
    public let birthDay: Int?
    public let birthPrecision: String?
    public let birthIsEstimated: Bool?
    public let ageMonthsObserved: Int?
    public let ageObservedAt: Date?
    public let goals: FlexibleStringList?
    public let avoidance: PetAvoidance?

    public init(type: String? = nil,
                petName: String? = nil,
                breed: String? = nil,
                dogSize: String? = nil,
                birthYear: Int? = nil,
                birthMonth: Int? = nil,
                birthDay: Int? = nil,
                birthPrecision: String? = nil,
                birthIsEstimated: Bool? = nil,
                ageMonthsObserved: Int? = nil,
                ageObservedAt: Date? = nil,
                goals: FlexibleStringList? = nil,
                avoidance: PetAvoidance? = nil) {
        self.type = type
        self.petName = petName
        self.breed = breed
        self.dogSize = dogSize
        self.birthYear = birthYear
        self.birthMonth = birthMonth
        self.birthDay = birthDay
        self.birthPrecision = birthPrecision
        self.birthIsEstimated = birthIsEstimated
        self.ageMonthsObserved = ageMonthsObserved
        self.ageObservedAt = ageObservedAt
        self.goals = goals
        self.avoidance = avoidance
    }
}

/// 宠物摘要（`/me`、`/pets` 内嵌）。
///
/// 旧字段 `name/species/breed/age_months/avatar_url` 继续保留；canonical 新响应在每只宠物
/// 增加 `profile_version` 和 `pet_information`。顶层 `birth_*` 是兼容字段。所有新增字段
/// 可空，旧响应/旧客户端仍可解码；**不会把未知 age_months 默认为 12**。
public struct PetSummary: Codable, Equatable, Sendable, Identifiable {
    public let petId: String
    public let name: String?
    public let species: String?
    public let breed: String?
    public let dogSize: String?
    public let ageMonths: Int?
    public let avatarUrl: URL?

    // Canonical lifetime additions.
    public let profileVersion: Int?
    public let petInformation: PetInformation?
    public let birthYear: Int?
    public let birthMonth: Int?
    public let birthDay: Int?
    public let birthPrecision: String?
    public let birthIsEstimated: Bool?
    public let ageMonthsObserved: Int?
    public let ageObservedAt: Date?
    public let goals: FlexibleStringList?
    public let avoidance: PetAvoidance?

    public init(petId: String,
                name: String? = nil,
                species: String? = nil,
                breed: String? = nil,
                dogSize: String? = nil,
                ageMonths: Int? = nil,
                avatarUrl: URL? = nil,
                profileVersion: Int? = nil,
                petInformation: PetInformation? = nil,
                birthYear: Int? = nil,
                birthMonth: Int? = nil,
                birthDay: Int? = nil,
                birthPrecision: String? = nil,
                birthIsEstimated: Bool? = nil,
                ageMonthsObserved: Int? = nil,
                ageObservedAt: Date? = nil,
                goals: FlexibleStringList? = nil,
                avoidance: PetAvoidance? = nil) {
        self.petId = petId
        self.name = name
        self.species = species
        self.breed = breed
        self.dogSize = dogSize
        self.ageMonths = ageMonths
        self.avatarUrl = avatarUrl
        self.profileVersion = profileVersion
        self.petInformation = petInformation
        self.birthYear = birthYear
        self.birthMonth = birthMonth
        self.birthDay = birthDay
        self.birthPrecision = birthPrecision
        self.birthIsEstimated = birthIsEstimated
        self.ageMonthsObserved = ageMonthsObserved
        self.ageObservedAt = ageObservedAt
        self.goals = goals
        self.avoidance = avoidance
    }

    public var id: String { petId }

    /// Nested canonical fields win; top-level birth_* remain a compatibility fallback.
    public var resolvedName: String? { petInformation?.petName ?? name }
    public var resolvedSpecies: String? { petInformation?.type ?? species }
    public var resolvedBreed: String? { petInformation?.breed ?? breed }
    public var resolvedDogSize: String? { petInformation?.dogSize ?? dogSize }
    public var resolvedBirthYear: Int? { petInformation?.birthYear ?? birthYear }
    public var resolvedBirthMonth: Int? { petInformation?.birthMonth ?? birthMonth }
    public var resolvedBirthDay: Int? { petInformation?.birthDay ?? birthDay }
    public var resolvedBirthPrecision: String? {
        (petInformation?.birthPrecision ?? birthPrecision)?.lowercased()
    }
    public var resolvedBirthIsEstimated: Bool {
        petInformation?.birthIsEstimated ?? birthIsEstimated ?? false
    }
    public var resolvedObservedAgeMonths: Int? {
        petInformation?.ageMonthsObserved ?? ageMonthsObserved
    }
    public var resolvedObservedAt: Date? {
        petInformation?.ageObservedAt ?? ageObservedAt
    }
    public var resolvedGoals: [String] { (petInformation?.goals ?? goals)?.values ?? [] }
    public var resolvedAvoidance: PetAvoidance? { petInformation?.avoidance ?? avoidance }
    public var resolvedAvoidanceItems: [String] { resolvedAvoidance?.items ?? [] }

    /// Local age derivation, never rewriting the server's observed snapshot.
    /// DOB (day/month/year precision) wins; otherwise observed age + elapsed months.
    /// Unknown returns nil so the UI can say “年龄未知” instead of assuming 12 months.
    public func derivedAgeMonths(now: Date = Date()) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let year = resolvedBirthYear
        let month = resolvedBirthMonth
        let day = resolvedBirthDay
        let precision = resolvedBirthPrecision
        if let year {
            if precision == "day", let month, let day,
               let start = calendar.date(from: DateComponents(year: year, month: month, day: day)) {
                return completedMonths(from: start, to: now)
            }
            if precision == "month" || (precision != "year" && month != nil) {
                if let month,
                   let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)) {
                    return completedMonths(from: start, to: now)
                }
            }
            // Year-only precision: report whole years, not invented months.
            let nowYear = calendar.component(.year, from: now)
            return max(0, (nowYear - year) * 12)
        }
        if let observed = resolvedObservedAgeMonths, let observedAt = resolvedObservedAt {
            return max(0, observed + completedMonths(from: observedAt, to: now))
        }
        return nil
    }

    /// Python `_completed_months` parity: clamp a 31st birthday to the end of a shorter
    /// current month, so Jan 31 -> Feb 28 counts as one completed month (not zero).
    private func completedMonths(from start: Date, to end: Date) -> Int {
        guard end >= start else { return 0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let startParts = calendar.dateComponents([.year, .month, .day], from: start)
        let endParts = calendar.dateComponents([.year, .month, .day], from: end)
        guard let startYear = startParts.year, let startMonth = startParts.month,
              let startDay = startParts.day, let endYear = endParts.year,
              let endMonth = endParts.month, let endDay = endParts.day else { return 0 }
        var months = (endYear - startYear) * 12 + endMonth - startMonth
        let daysInEndMonth = calendar.range(of: .day, in: .month, for: end)?.count ?? 28
        let anniversaryDay = min(startDay, daysInEndMonth)
        if endDay < anniversaryDay { months -= 1 }
        return max(0, months)
    }

    /// Human-facing local age. Unknown is explicit; legacy static `age_months` is labelled as
    /// a historical record, never silently treated as current/derived.
    public func ageDescription(now: Date = Date()) -> String {
        if let months = derivedAgeMonths(now: now) {
            let precision = resolvedBirthPrecision
            let approximate = resolvedBirthIsEstimated || precision != "day"
            let prefix = approximate ? "约 " : ""
            if precision == "year" {
                let years = months / 12
                if years <= 0 {
                    return "未满1岁（仅知出生年份）"
                }
                return "\(prefix)\(years) 岁"
            }
            let years = months / 12
            let remaining = months % 12
            if years > 0 && remaining > 0 {
                return "\(prefix)\(years) 岁 \(remaining) 个月"
            }
            if years > 0 { return "\(prefix)\(years) 岁" }
            return "\(prefix)\(remaining) 个月"
        }
        if let ageMonths {
            return "记录月龄 \(ageMonths) 个月（历史值，未随时更新）"
        }
        return "年龄未知"
    }
}

/// `GET /mobile/v1/pets`。
public struct PetListResponse: Codable, Equatable, Sendable {
    public let pets: [PetSummary]

    public init(pets: [PetSummary]) {
        self.pets = pets
    }
}

// MARK: - 小家 / 模型清单

/// `GET /mobile/v1/pet-home?pet_id=...` 的清单。
///
/// 后端在没有宠物/未选中宠物时返回 `pet_id: null`，因此 `petId` 可选；
/// `fallback_reason` 是后端对「个人模型存在但格式不支持」的顶层说明。
public struct PetHomeManifest: Codable, Equatable, Sendable {
    public let petId: String?
    public let manifestVersion: Int?
    /// `default` | `personal`
    public let selected: String
    public let fallbackReason: String?
    public let avatarUrl: URL?
    public let defaultModel: DefaultModel
    public let personalModel: PersonalModel?

    public init(petId: String? = nil,
                manifestVersion: Int? = 1,
                selected: String,
                fallbackReason: String? = nil,
                avatarUrl: URL? = nil,
                defaultModel: DefaultModel,
                personalModel: PersonalModel? = nil) {
        self.petId = petId
        self.manifestVersion = manifestVersion
        self.selected = selected
        self.fallbackReason = fallbackReason
        self.avatarUrl = avatarUrl
        self.defaultModel = defaultModel
        self.personalModel = personalModel
    }

    /// `selected` 的枚举视图；未知值安全降级为 `.default`。
    public var selectedKind: PetHomeSelection {
        PetHomeSelection(rawValue: selected.lowercased()) ?? .default
    }
}

public enum PetHomeSelection: String, Codable, CaseIterable, Sendable {
    case `default` = "default"
    case personal
}

/// 默认宠物模型（网站首页金毛 GLB，公开只读 `public-assets`）。
public struct DefaultModel: Codable, Equatable, Sendable {
    public let role: String?
    /// 后端字段名是 `static`（Swift 关键字），这里映射为 `isStatic`。
    public let isStatic: Bool?
    public let isDefault: Bool?
    public let format: String
    public let mime: String?
    public let bytes: Int64?
    public let sha256: String?
    public let url: String
    public let source: String?

    public init(role: String? = "default",
                isStatic: Bool? = true,
                isDefault: Bool? = true,
                format: String = "glb",
                mime: String? = "model/gltf-binary",
                bytes: Int64? = nil,
                sha256: String? = nil,
                url: String,
                source: String? = nil) {
        self.role = role
        self.isStatic = isStatic
        self.isDefault = isDefault
        self.format = format
        self.mime = mime
        self.bytes = bytes
        self.sha256 = sha256
        self.url = url
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case isStatic = "static"
        case isDefault = "isDefault"
        case format, mime, bytes, sha256, url, source
    }
}

/// 个人模型：`url` 指向需 Bearer 的 `/mobile/v1/assets/{asset_id}/download`。
public struct PersonalModel: Codable, Equatable, Sendable {
    public let assetId: String?
    public let role: String?
    public let isStatic: Bool?
    public let isDefault: Bool?
    public let format: String
    public let mime: String?
    public let bytes: Int64?
    public let sha256: String?
    public let url: String
    public let source: String?
    public let sourceJobId: String?
    public let isReferenceModel: Bool?
    public let breedSlug: String?

    public init(assetId: String? = nil,
                role: String? = "personal",
                isStatic: Bool? = false,
                isDefault: Bool? = false,
                format: String = "glb",
                mime: String? = "model/gltf-binary",
                bytes: Int64? = nil,
                sha256: String? = nil,
                url: String,
                source: String? = nil,
                sourceJobId: String? = nil,
                isReferenceModel: Bool? = nil,
                breedSlug: String? = nil) {
        self.assetId = assetId
        self.role = role
        self.isStatic = isStatic
        self.isDefault = isDefault
        self.format = format
        self.mime = mime
        self.bytes = bytes
        self.sha256 = sha256
        self.url = url
        self.source = source
        self.sourceJobId = sourceJobId
        self.isReferenceModel = isReferenceModel
        self.breedSlug = breedSlug
    }

    private enum CodingKeys: String, CodingKey {
        case assetId
        case role
        case isStatic = "static"
        case isDefault = "isDefault"
        case format, mime, bytes, sha256, url, source
        case sourceJobId, isReferenceModel, breedSlug
    }
}

// MARK: - 资产

/// `GET /mobile/v1/assets` 的资产条目。
public struct AssetItem: Codable, Equatable, Sendable, Identifiable {
    public let assetId: String
    public let petId: String?
    /// Website archive role; `upload` identifies the historical original image.
    public let kindRole: String?
    /// `photo` | `tryon` | `outfit` | `cartoon` | `model` | `manifest`
    public let kind: String?
    public let format: String?
    public let mime: String?
    public let bytes: Int64?
    public let sha256: String?
    public let sourceJobId: String?
    public let createdAt: Date?
    /// 需 Bearer 的下载路径；数据层负责带授权取字节，绝不当作公开链接分发。
    public let downloadUrl: String?
    public let source: String?
    public let isReferenceModel: Bool?
    public let breedSlug: String?

    public init(assetId: String,
                petId: String? = nil,
                kindRole: String? = nil,
                kind: String? = nil,
                format: String? = nil,
                mime: String? = nil,
                bytes: Int64? = nil,
                sha256: String? = nil,
                sourceJobId: String? = nil,
                createdAt: Date? = nil,
                downloadUrl: String? = nil,
                source: String? = nil,
                isReferenceModel: Bool? = nil,
                breedSlug: String? = nil) {
        self.assetId = assetId
        self.petId = petId
        self.kindRole = kindRole
        self.kind = kind
        self.format = format
        self.mime = mime
        self.bytes = bytes
        self.sha256 = sha256
        self.sourceJobId = sourceJobId
        self.createdAt = createdAt
        self.downloadUrl = downloadUrl
        self.source = source
        self.isReferenceModel = isReferenceModel
        self.breedSlug = breedSlug
    }

    public var id: String { assetId }
}

/// 游标分页：`next_cursor` 为不透明字符串，null 表示没有下一页。
public struct AssetPage: Codable, Equatable, Sendable {
    public let items: [AssetItem]
    public let nextCursor: String?

    public init(items: [AssetItem], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }

    public var hasMore: Bool { nextCursor != nil }
}

/// `GET /mobile/v1/assets/{asset_id}/manifest`。
public struct AssetManifest: Codable, Equatable, Sendable {
    public let assetId: String
    public let format: String?
    public let mime: String?
    public let bytes: Int64?
    public let sha256: String?
    public let sourceJobId: String?
    public let available: Bool?

    public init(assetId: String,
                format: String? = nil,
                mime: String? = nil,
                bytes: Int64? = nil,
                sha256: String? = nil,
                sourceJobId: String? = nil,
                available: Bool? = nil) {
        self.assetId = assetId
        self.format = format
        self.mime = mime
        self.bytes = bytes
        self.sha256 = sha256
        self.sourceJobId = sourceJobId
        self.available = available
    }

    public var isAvailable: Bool { available ?? true }
}

// MARK: - 发现 / 附近

/// `POST /mobile/v1/discovery` 的响应。
public struct DiscoveryStatus: Codable, Equatable, Sendable {
    public let enabled: Bool
    /// 服务端量化后的固定网格，形如 `"x:y"`。
    public let grid: String?
    public let expiresAt: Date?
    public let radiusKm: Int?

    public init(enabled: Bool, grid: String? = nil, expiresAt: Date? = nil, radiusKm: Int? = nil) {
        self.enabled = enabled
        self.grid = grid
        self.expiresAt = expiresAt
        self.radiusKm = radiusKm
    }
}

/// 上报给服务端的坐标（服务端立即量化为固定网格，不保存精确 GPS）。
public struct GeoCoordinate: Codable, Equatable, Sendable {
    public let lat: Double
    public let lon: Double

    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }
}

/// 后端返回的粗区域（只有网格与文案，不含精确经纬度）。
public struct CoarseRegion: Codable, Equatable, Sendable {
    public let grid: String
    public let label: String?

    public init(grid: String, label: String? = nil) {
        self.grid = grid
        self.label = label
    }
}

/// `GET /mobile/v1/nearby` 的响应。
public struct NearbyResponse: Codable, Equatable, Sendable {
    public let items: [NearbyItem]
    public let radiusKm: Int?
    public let generatedAt: Date?

    public init(items: [NearbyItem], radiusKm: Int? = nil, generatedAt: Date? = nil) {
        self.items = items
        self.radiusKm = radiusKm
        self.generatedAt = generatedAt
    }
}

/// 附近/联系响应里只暴露公开宠物资料的子集（无邮箱、无精确位置）。
///
/// 后端对「已认证但还没有宠物」的账号返回 `pet: {name: null, ...}`，因此 `name` 可选，
/// 不能用非空 String 拖垮 nearby / 联系列表的整体解码。
public struct PublicPetSummary: Codable, Equatable, Sendable {
    public let name: String?
    public let species: String?
    public let breed: String?
    public let ageMonths: Int?
    public let avatarUrl: URL?

    public init(name: String? = nil,
                species: String? = nil,
                breed: String? = nil,
                ageMonths: Int? = nil,
                avatarUrl: URL? = nil) {
        self.name = name
        self.species = species
        self.breed = breed
        self.ageMonths = ageMonths
        self.avatarUrl = avatarUrl
    }
}

/// Additive social fields in nearby/contact/request responses.
///
/// These are optional so an older canonical backend (or a pre-social migration response) still
/// decodes. `authenticatedPath` is `/mobile/v1/users/{public_ref}/avatar`; never a private media
/// path or email. Default avatars are represented by `defaultKey` and rendered locally.
public struct SocialAvatarReference: Codable, Equatable, Sendable {
    /// `none` | `default` | `upload`
    public let kind: String?
    public let defaultKey: String?
    public let authenticatedPath: String?
    public let available: Bool?

    public init(kind: String? = nil,
                defaultKey: String? = nil,
                authenticatedPath: String? = nil,
                available: Bool? = nil) {
        self.kind = kind
        self.defaultKey = defaultKey
        self.authenticatedPath = authenticatedPath
        self.available = available
    }

    public var isDefault: Bool { kind == "default" }
    public var isUpload: Bool { kind == "upload" }
}

public struct NearbyItem: Codable, Equatable, Sendable, Identifiable {
    public let publicRef: String
    public let pet: PublicPetSummary?
    public let coarseRegion: CoarseRegion?
    /// `lt_1km` | `1_3km` | `3_10km` | `10_25km`
    public let distanceBucket: String?
    /// Additive public social fields; optional for backward compatibility.
    public let socialDisplayName: String?
    public let socialAvatar: SocialAvatarReference?

    public init(publicRef: String,
                pet: PublicPetSummary? = nil,
                coarseRegion: CoarseRegion? = nil,
                distanceBucket: String? = nil,
                socialDisplayName: String? = nil,
                socialAvatar: SocialAvatarReference? = nil) {
        self.publicRef = publicRef
        self.pet = pet
        self.coarseRegion = coarseRegion
        self.distanceBucket = distanceBucket
        self.socialDisplayName = socialDisplayName
        self.socialAvatar = socialAvatar
    }

    public var id: String { publicRef }
}

// MARK: - 联系 / 消息 / 拉黑

/// `POST /mobile/v1/contacts/requests` 的响应。
///
/// 后端两种路径：
/// - 普通申请：`{request_id, direction, status:"pending", created_at}`；
/// - 自动互加（对方已有 pending 反向申请）：`{request_id?, contact_id, status:"accepted", auto_accepted:true}`。
/// 因此 `requestId` 不能必填，`requestId ?? contactId` 任一存在即可用于后续处理。
public struct ContactRequestCreated: Codable, Equatable, Sendable {
    public let requestId: String?
    public let contactId: String?
    public let status: String?
    public let createdAt: Date?
    public let autoAccepted: Bool?
    public let message: String?

    public init(requestId: String? = nil,
                contactId: String? = nil,
                status: String? = nil,
                createdAt: Date? = nil,
                autoAccepted: Bool? = nil,
                message: String? = nil) {
        self.requestId = requestId
        self.contactId = contactId
        self.status = status
        self.createdAt = createdAt
        self.autoAccepted = autoAccepted
        self.message = message
    }

    /// 可用的标识：普通申请为 request_id，自动互加为 contact_id。
    public var identifier: String? { requestId ?? contactId }
    public var isAutoAccepted: Bool { autoAccepted ?? false }
}

/// 请求列表条目。
public struct ContactRequestItem: Codable, Equatable, Sendable, Identifiable {
    public let requestId: String
    /// `incoming` | `outgoing`
    public let direction: String?
    public let userPublicRef: String?
    public let pet: PublicPetSummary?
    public let status: String?
    public let createdAt: Date?
    public let socialDisplayName: String?
    public let socialAvatar: SocialAvatarReference?

    public init(requestId: String,
                direction: String? = nil,
                userPublicRef: String? = nil,
                pet: PublicPetSummary? = nil,
                status: String? = nil,
                createdAt: Date? = nil,
                socialDisplayName: String? = nil,
                socialAvatar: SocialAvatarReference? = nil) {
        self.requestId = requestId
        self.direction = direction
        self.userPublicRef = userPublicRef
        self.pet = pet
        self.status = status
        self.createdAt = createdAt
        self.socialDisplayName = socialDisplayName
        self.socialAvatar = socialAvatar
    }

    public var id: String { requestId }
}

public struct ContactRequestListResponse: Codable, Equatable, Sendable {
    public let items: [ContactRequestItem]

    public init(items: [ContactRequestItem]) {
        self.items = items
    }
}

/// accept / decline 响应：`{request_id, status, contact_id}`。
public struct ContactActionResponse: Codable, Equatable, Sendable {
    public let requestId: String?
    public let contactId: String?
    public let status: String?
    public let autoAccepted: Bool?

    public init(requestId: String? = nil,
                contactId: String? = nil,
                status: String? = nil,
                autoAccepted: Bool? = nil) {
        self.requestId = requestId
        self.contactId = contactId
        self.status = status
        self.autoAccepted = autoAccepted
    }
}

/// `GET /mobile/v1/contacts` 条目。
public struct ContactItem: Codable, Equatable, Sendable, Identifiable {
    public let contactId: String
    public let userPublicRef: String?
    public let pet: PublicPetSummary?
    public let since: Date?
    public let socialDisplayName: String?
    public let socialAvatar: SocialAvatarReference?

    public init(contactId: String,
                userPublicRef: String? = nil,
                pet: PublicPetSummary? = nil,
                since: Date? = nil,
                socialDisplayName: String? = nil,
                socialAvatar: SocialAvatarReference? = nil) {
        self.contactId = contactId
        self.userPublicRef = userPublicRef
        self.pet = pet
        self.since = since
        self.socialDisplayName = socialDisplayName
        self.socialAvatar = socialAvatar
    }

    public var id: String { contactId }
}

public struct ContactListResponse: Codable, Equatable, Sendable {
    public let items: [ContactItem]

    public init(items: [ContactItem]) {
        self.items = items
    }
}

/// 私聊消息。`client_id` 用于 `(contact_id, client_id)` 幂等发送。
public struct ChatMessage: Codable, Equatable, Sendable, Identifiable {
    public let messageId: String
    public let contactId: String?
    public let body: String
    public let createdAt: Date?
    public let clientId: String?
    /// `me` | `them`
    public let sender: String?

    public init(messageId: String,
                contactId: String? = nil,
                body: String,
                createdAt: Date? = nil,
                clientId: String? = nil,
                sender: String? = nil) {
        self.messageId = messageId
        self.contactId = contactId
        self.body = body
        self.createdAt = createdAt
        self.clientId = clientId
        self.sender = sender
    }

    public var id: String { messageId }
    public var isFromMe: Bool { sender?.lowercased() == "me" }
}

/// 消息分页。
///
/// 后端游标是 Unix 秒 Float（`next_before`），并新增 `next_before_id` 作为同一时间戳内的
/// 二级排序键：第二页请求必须同时带 `before` + `before_id`，否则同秒消息可能漏页。
public struct MessagePage: Codable, Equatable, Sendable {
    public let items: [ChatMessage]
    public let nextBefore: Double?
    public let nextBeforeId: String?

    public init(items: [ChatMessage], nextBefore: Double? = nil, nextBeforeId: String? = nil) {
        self.items = items
        self.nextBefore = nextBefore
        self.nextBeforeId = nextBeforeId
    }

    public var hasMore: Bool { nextBefore != nil || nextBeforeId != nil }

    private enum CodingKeys: String, CodingKey {
        case items
        case nextBefore
        case nextBeforeId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([ChatMessage].self, forKey: .items) ?? []
        nextBefore = MessagePage.decodeFlexibleDouble(container, forKey: .nextBefore)
        nextBeforeId = try container.decodeIfPresent(String.self, forKey: .nextBeforeId)
    }

    /// 游标既可能是 JSON number（真实后端），也可能是数字字符串（代理层）。
    private static func decodeFlexibleDouble(_ container: KeyedDecodingContainer<CodingKeys>,
                                             forKey key: CodingKeys) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            return Double(text)
        }
        return nil
    }
}

/// `GET /mobile/v1/blocks` 条目。
///
/// 真实后端返回 `{user_public_ref, created_at}`；DELETE 需要被拉黑方的 public_ref，
/// 因此 `resolvedPublicRef` 优先取 `user_public_ref`，并兼容旧字段 `target_public_ref`。
public struct BlockItem: Codable, Equatable, Sendable {
    public let userPublicRef: String?
    public let publicRef: String?
    public let targetPublicRef: String?
    public let createdAt: Date?
    /// 兼容旧字段名 `blocked_at`。
    public let blockedAt: Date?

    public init(userPublicRef: String? = nil,
                publicRef: String? = nil,
                targetPublicRef: String? = nil,
                createdAt: Date? = nil,
                blockedAt: Date? = nil) {
        self.userPublicRef = userPublicRef
        self.publicRef = publicRef
        self.targetPublicRef = targetPublicRef
        self.createdAt = createdAt
        self.blockedAt = blockedAt
    }

    /// 被拉黑方的 public ref：优先真实后端的 `user_public_ref`，再兼容旧字段。
    public var resolvedPublicRef: String? {
        userPublicRef ?? targetPublicRef ?? publicRef
    }

    /// 拉黑时间（真实后端 `created_at`，兼容旧字段 `blocked_at`）。
    public var createdAtDate: Date? { createdAt ?? blockedAt }
}

public struct BlockListResponse: Codable, Equatable, Sendable {
    public let items: [BlockItem]

    public init(items: [BlockItem]) {
        self.items = items
    }
}
