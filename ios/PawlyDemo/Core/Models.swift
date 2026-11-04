import Foundation

// MARK: - Scalar helpers

/// Loose JSON scalar used for appearance tokens and other open-ended payloads.
enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }
}

/// Decodes either a plain string or a language-keyed dictionary.
struct LocalizedText: Codable, Hashable {
    let values: [String: String]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            values = ["": text]
        } else if let map = try? container.decode([String: String].self) {
            values = map
        } else {
            values = [:]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values[""] ?? values["en"] ?? "")
    }

    func text(language: String) -> String? {
        values[language] ?? values[""] ?? values["en"] ?? values["zh-CN"] ?? values["es"] ?? values.values.first
    }
}

/// Accepts number or decimal string (e.g. discount rate 0.2 / "0.2").
struct RateValue: Codable, Hashable {
    let doubleValue: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            doubleValue = value
        } else if let text = try? container.decode(String.self), let value = Double(text) {
            doubleValue = value
        } else {
            doubleValue = 0
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(doubleValue)
    }
}

// MARK: - Money

struct Money: Codable, Hashable {
    let amount: String
    let currencyCode: String

    init(amount: String, currencyCode: String = "USD") {
        self.amount = amount
        self.currencyCode = currencyCode
    }

    var decimal: Decimal {
        Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")) ?? 0
    }

    var display: String {
        let symbol: String
        switch currencyCode {
        case "USD": symbol = "$"
        case "EUR": symbol = "€"
        case "GBP": symbol = "£"
        case "CNY": symbol = "¥"
        default: symbol = "\(currencyCode) "
        }
        return symbol + Self.twoDecimals(amount)
    }

    static func twoDecimals(_ raw: String) -> String {
        let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) ?? 0
        var rounded = Decimal()
        var source = value
        NSDecimalRound(&rounded, &source, 2, .plain)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.groupingSeparator = ""
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSDecimalNumber(decimal: rounded)) ?? NSDecimalNumber(decimal: rounded).stringValue
    }

    static func sum(_ values: [Money], currency: String) -> Money {
        let total = values.reduce(Decimal(0)) { $0 + $1.decimal }
        return Money(amount: NSDecimalNumber(decimal: total).stringValue, currencyCode: currency)
    }
}

// MARK: - Core entities

struct MarketContext: Codable, Hashable {
    let countryCode: String
    let languageCode: String
    let currencyCode: String?
}

struct Profile: Codable, Hashable, Identifiable {
    let profileId: String
    let subjectId: String
    let contactEmail: String
    let fullName: String
    let contactEmailVerifiedAt: String?
    let revision: String
    let updatedAt: String

    var id: String { profileId }

    var initials: String {
        let trimmed = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "🐾" }
        return String(trimmed.prefix(1))
    }
}

struct UserPreferences: Codable, Hashable {
    let locale: String
    let themePreference: String
    let revision: String
}

struct Pet: Codable, Hashable, Identifiable {
    let petId: String
    let name: String
    let species: String
    let dogSize: String?
    let reportedAgeMonths: Int?
    let ageReportedAt: String?
    let birthDate: String?
    let breedCode: String?
    let breedLabel: String?
    let breedSource: String?
    let breedConfidence: String?
    let neckCm: String?
    let chestCm: String?
    let backLengthCm: String?
    let weightKg: String?
    let measurementSource: String?
    let measuredAt: String?
    let revision: String
    let currentAvatarVersionId: String?
    let avatarAssetId: String?
    let avatarUrl: String?
    let updatedAt: String?
    let demoLatestRecommendationId: String?

    var id: String { petId }
}

struct PetList: Codable {
    let items: [Pet]
    let nextCursor: String?
}

struct MeCapabilities: Codable, Hashable {
    let channels: [String]?
    let canGenerate: Bool?
    let shopifyConnected: Bool?
}

struct SessionInfo: Codable, Hashable {
    let expiresAt: String?
}

struct MeResponse: Codable {
    let subjectId: String
    let subjectKind: String
    let shopId: String?
    let shopifyCustomerGid: String?
    let profile: Profile?
    let preferences: UserPreferences?
    let pets: [Pet]?
    let capabilities: MeCapabilities?
    let session: SessionInfo?
    let claimCode: String?
    let latestRecommendationId: String?
    let recommendationId: String?
    let demoLatestRecommendationId: String?

    var resolvedRecommendationId: String? {
        latestRecommendationId ?? recommendationId ?? demoLatestRecommendationId
    }
}

struct ConsentItem: Codable, Hashable, Identifiable {
    let consentEventId: String
    let scope: String
    let granted: Bool
    let policyVersion: String
    let channel: String?
    let occurredAt: String

    var id: String { consentEventId }
}

struct ConsentList: Codable {
    let items: [ConsentItem]
}

// MARK: - Catalog

struct SelectedOption: Codable, Hashable {
    let name: String
    let value: String
    let label: LocalizedText?

    func displayLabel(language: String) -> String {
        label?.text(language: language) ?? L10n.optionValueLabel(value, language)
    }
}

struct Variant: Codable, Hashable, Identifiable {
    let variantGid: String
    let productGid: String?
    let sku: String?
    let selectedOptions: [SelectedOption]
    let price: Money
    let compareAtPrice: Money?
    let availableForSale: Bool

    var id: String { variantGid }
}

struct MediaItem: Codable, Hashable, Identifiable {
    let mediaId: String
    let type: String
    let url: String
    let mimeType: String
    let alt: LocalizedText?
    let width: Int?
    let height: Int?

    var id: String { mediaId }
}

struct ProductCapabilities: Codable, Hashable {
    let has3D: Bool?
    let hasGLB: Bool?
    let hasUSDZ: Bool?
    let hasSkinning: Bool?
    let supportedActions: [String]?

    // The decoder uses .convertFromSnakeCase: raw values must be the converted keys.
    enum CodingKeys: String, CodingKey {
        case has3D = "has3D"
        case hasGLB = "hasGlb"
        case hasUSDZ = "hasUsdz"
        case hasSkinning = "hasSkinning"
        case supportedActions = "supportedActions"
    }
}

struct ProductOptionValue: Codable, Hashable, Identifiable {
    let value: String
    let label: LocalizedText?
    let labels: [String: String]?

    var id: String { value }

    func displayLabel(language: String) -> String {
        if let labels, let text = labels[language] ?? labels["en"] ?? labels.values.first { return text }
        if let label, let text = label.text(language: language) { return text }
        return L10n.optionValueLabel(value, language)
    }
}

struct ProductOption: Codable, Hashable, Identifiable {
    let name: String
    let values: [ProductOptionValue]
    let label: LocalizedText?

    var id: String { name }

    func displayName(language: String) -> String {
        label?.text(language: language) ?? L10n.optionNameLabel(name, language)
    }
}

struct Product: Codable, Hashable, Identifiable {
    let productGid: String
    let handle: String
    let title: String
    let descriptionText: String
    let audienceCodes: [String]?
    let activityCodes: [String]?
    let variants: [Variant]
    let media: [MediaItem]
    let context: MarketContext?
    let syncedAt: String?
    let productType: String?
    let categoryCodes: [String]?
    let tags: [String]?
    let featured: Bool?
    let badge: LocalizedText?
    let options: [ProductOption]?
    let fitSummary: LocalizedText?
    let capabilities: ProductCapabilities?

    var id: String { productGid }

    var images: [MediaItem] { media.filter { $0.type == "image" } }

    var primaryImageURL: String? {
        if let first = images.first { return first.url }
        return media.first?.url
    }

    var priceRange: Money? {
        let prices = variants.map(\.price)
        guard let minPrice = prices.min(by: { $0.decimal < $1.decimal }) else { return nil }
        let maxPrice = prices.max(by: { $0.decimal < $1.decimal })
        if let maxPrice, maxPrice.decimal > minPrice.decimal {
            return Money(amount: "\(minPrice.amount)", currencyCode: minPrice.currencyCode)
        }
        return minPrice
    }

    var hasPriceRange: Bool {
        guard let maxPrice = variants.map(\.price).max(by: { $0.decimal < $1.decimal }),
              let minPrice = variants.map(\.price).min(by: { $0.decimal < $1.decimal }) else { return false }
        return maxPrice.decimal > minPrice.decimal
    }

    var isAvailable: Bool { variants.contains(where: \.availableForSale) }
}

struct ProductList: Codable {
    let items: [Product]
    let nextCursor: String?
}

struct RecommendationItem: Codable, Hashable, Identifiable {
    let itemId: String
    let rank: Int
    let reasonCode: String?
    let reasonText: String?
    let product: Product
    let variantGid: String?

    var id: String { itemId }

    func localizedReason(language: String) -> String? {
        guard let reasonText, !reasonText.isEmpty else { return nil }
        return reasonText
    }
}

struct Recommendation: Codable {
    let recommendationId: String
    let subjectId: String?
    let petId: String?
    let ruleVersion: String?
    let createdAt: String?
    let context: MarketContext?
    let items: [RecommendationItem]
}

// MARK: - Cart / checkout

struct DemoDiscountPreview: Codable, Hashable {
    let eligible: Bool
    let rate: RateValue?
    let amountOff: Money?
    let note: String?
}

struct CartLine: Codable, Hashable, Identifiable {
    let lineId: String
    let variantGid: String
    let quantity: Int
    let customizationId: String?
    let cost: Money
    let title: String?
    let petId: String?
    let productGid: String?
    let imageUrl: String?
    let variantTitle: String?

    var id: String { lineId }
}

struct Cart: Codable, Hashable {
    let cartId: String
    let revision: String
    let context: MarketContext?
    let lines: [CartLine]
    let estimatedTotal: Money
    let warnings: [String]?
    let demoDiscountPreview: DemoDiscountPreview?

    var itemCount: Int { lines.reduce(0) { $0 + $1.quantity } }

    /// Pre-discount sum of the cart lines (demo: `estimatedTotal` already
    /// includes the demo discount, so the UI shows this as 小计 and the
    /// discount as a separate negative row).
    var linesSubtotal: Money {
        let total = lines.reduce(Decimal(0)) { $0 + $1.cost.decimal }
        let formatted = String(format: "%.2f", NSDecimalNumber(decimal: total).doubleValue)
        return Money(amount: formatted, currencyCode: estimatedTotal.currencyCode)
    }
}

struct Checkout: Codable {
    let checkoutUrl: String
    let issuedAt: String?
}

struct CheckoutSession: Codable {
    let status: String
    let cart: Cart?
    let orderId: String?
}

struct OrderLine: Codable, Hashable {
    let title: String?
    let quantity: Int?
    let cost: Money?
    let variantGid: String?
}

struct Order: Codable {
    let orderId: String
    let status: String
    let total: Money
    let lines: [OrderLine]?
    let createdAt: String?
    let confirmedAt: String?
}

// MARK: - Auth

struct AuthSession: Codable {
    let subjectId: String
    let accessToken: String
    let expiresAt: String?
    let sourceExpiresAt: String?
    let demoNote: String?
    let claimCode: String?
    let mergedGuestSubjectId: String?
    let moved: MoveSummary?
}

struct MoveSummary: Codable, Hashable {
    let pets: Int?
    let profiles: Int?
    let submissions: Int?
}

// MARK: - Uploads / assets

struct UploadTicket: Codable {
    let uploadId: String
    let assetId: String
    let method: String
    let url: String
    let headers: [String: String]
    let expiresAt: String
}

struct Asset: Codable {
    let assetId: String
    let state: String
    let mimeType: String?
    let byteSize: Int?
    let sha256: String?
    let revision: String
}

struct AssetAccess: Codable {
    let assetId: String
    let url: String
    let expiresAt: String
    let mimeType: String
    let byteSize: Int
    let sha256: String
}

// MARK: - Generation jobs

struct GenerationOutput: Codable, Hashable, Identifiable {
    let role: String
    let assetId: String
    let state: String
    let accessUrl: String?
    let errorCode: String?

    var id: String { role }
}

struct GenerationJob: Codable, Hashable, Identifiable {
    let jobId: String
    let pipelineId: String?
    let petId: String
    let taskType: String?
    let status: String
    let stage: String
    let progress: Int?
    let revision: String
    let outputs: [GenerationOutput]
    let errorCode: String?
    let retryable: Bool?
    let updatedAt: String?
    let createdAt: String?

    var id: String { jobId }

    var isTerminal: Bool {
        ["succeeded", "failed", "cancelled"].contains(status)
    }

    func output(role: String) -> GenerationOutput? {
        outputs.first { $0.role == role }
    }
}

struct GenerationJobList: Codable {
    let items: [GenerationJob]
    let nextCursor: String?
}

struct GenerationTemplate: Codable, Hashable, Identifiable {
    let templateVersionId: String
    let species: String
    let templateKey: String?
    let version: String?
    let rigVersion: String?
    let hasSkeleton: Bool?
    let hasSkinning: Bool?
    let availableActions: [String]?
    let posterUrl: String?
    let formats: [String: String]?

    var id: String { templateVersionId }
}

struct GenerationTemplateList: Codable {
    let items: [GenerationTemplate]
}

// MARK: - Appearance

struct AppearancePayload: Codable {
    let schemaVersion: Int
    let releaseId: String
    let headRevision: String
    let rendererKey: String
    let minClientCapability: Int?
    let tokens: [String: JSONValue]
    let bindings: [JSONValue]?
    let publishedAt: String?
}

// MARK: - Privacy

struct PrivacyRequest: Codable, Identifiable {
    let requestId: String
    let status: String
    let kind: String?
    let receivedAt: String?
    let completedAt: String?

    var id: String { requestId }
}

// MARK: - Error payload

struct FieldError: Codable, Hashable {
    let field: String
    let code: String?
    let message: String?
}

struct ErrorBody: Codable {
    let code: String
    let message: String
    let requestId: String?
    let retryable: Bool?
    let fieldErrors: [FieldError]?
}
