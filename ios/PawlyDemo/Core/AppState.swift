import SwiftUI

enum PawlyTab: Hashable {
    case home, shop, generate, profile
}

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isError: Bool
}

@MainActor
final class AppState: ObservableObject {
    // Session
    @Published var accessToken: String?
    @Published var isBootstrapping = true
    @Published var isAuthBusy = false
    @Published var authError: String?

    // Identity data
    @Published var me: MeResponse?
    @Published var pets: [Pet] = []
    @Published var selectedPetId: String?
    @Published var preferences: UserPreferences?
    @Published var appearance: AppearancePayload?
    @Published var backendReachable: Bool?

    // Commerce
    @Published var cart: Cart?

    // UI preferences
    @Published var language: String {
        didSet {
            api.language = language
            UserDefaults.standard.set(language, forKey: Self.languageKey)
        }
    }
    @Published var themePreference: String {
        didSet {
            UserDefaults.standard.set(themePreference, forKey: Self.themeKey)
        }
    }

    // Navigation / global UI
    @Published var selectedTab: PawlyTab = .home
    @Published var showCart = false
    @Published var toast: ToastMessage?
    @Published var authEpoch = 0
    @Published var pendingProductGID: String?

    let api = APIClient()

    private static let languageKey = "pawly.language"
    private static let themeKey = "pawly.theme"
    private static let petKey = "pawly.selectedPet"

    private var toastTask: Task<Void, Never>?

    init() {
        language = UserDefaults.standard.string(forKey: Self.languageKey) ?? "zh-CN"
        themePreference = UserDefaults.standard.string(forKey: Self.themeKey) ?? "system"
        api.language = language
        selectedPetId = UserDefaults.standard.string(forKey: Self.petKey)
        api.onUnauthorized = { [weak self] in
            self?.handleUnauthorized()
        }
    }

    // MARK: - Derived

    var selectedPet: Pet? {
        if let selectedPetId, let match = pets.first(where: { $0.petId == selectedPetId }) {
            return match
        }
        return pets.first
    }

    var resolvedColorScheme: ColorScheme? {
        switch themePreference {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var cartCount: Int { cart?.itemCount ?? 0 }

    var isGuest: Bool { me?.subjectKind == "guest" }

    var claimCode: String? { me?.claimCode }

    var displayName: String {
        guard let name = me?.profile?.fullName, !name.isEmpty else {
            return me?.profile?.contactEmail ?? L10n.t("home.greetingPlain", language)
        }
        return name
    }

    var brandTagline: String {
        if let tokens = appearance?.tokens {
            let localizedKey = language == "zh-CN" ? "brand.tagline" : "brand.tagline.\(language)"
            if let value = tokens[localizedKey]?.stringValue, !value.isEmpty { return value }
            if let value = tokens["brand.tagline"]?.stringValue, !value.isEmpty { return value }
        }
        return L10n.t("brand.tagline", language)
    }

    var brandName: String {
        appearance?.tokens["brand.name"]?.stringValue ?? "Pawly"
    }

    var appearanceReleaseShort: String {
        guard let release = appearance?.releaseId else { return "—" }
        return String(release.prefix(8))
    }

    var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    func t(_ key: String) -> String { L10n.t(key, language) }
    func t(_ key: String, _ args: CVarArg...) -> String { String(format: L10n.t(key, language), arguments: args) }

    func pet(withID id: String?) -> Pet? {
        guard let id else { return nil }
        return pets.first { $0.petId == id }
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        guard isBootstrapping else { return }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-demoLogout") {
            clearLocalSession()
        }
#endif
        async let appearanceTask: Void = refreshAppearance()
        if let token = Keychain.loadToken() {
            accessToken = token
            api.token = token
            do {
                try await refreshMe(applyServerPreferences: true)
            } catch {
                if let apiError = error as? APIError, apiError.isUnauthorized {
                    clearLocalSession()
                }
                // Keep token for possibly transient network errors; views show retry states.
            }
        }
        await appearanceTask
        await checkHealth()
        isBootstrapping = false
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-demoAutoLogin"), accessToken == nil {
            await loginDemoCustomer()
        }
        await prepareDebugScreen()
        // Screenshot automation overrides are applied last so server preferences do not win.
        if let theme = Self.debugArgument("-theme"), ["system", "light", "dark"].contains(theme) {
            themePreference = theme
        }
        if let lang = Self.debugArgument("-lang"), L10n.supported.contains(lang) {
            language = lang
        }
#endif
    }

#if DEBUG
    static func debugArgument(_ flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// Debug-only navigation helper used to take deterministic simulator screenshots.
    func prepareDebugScreen() async {
        guard let screen = Self.debugArgument("-screen"), accessToken != nil else { return }
        switch screen {
        case "home":
            selectedTab = .home
        case "shop":
            selectedTab = .shop
        case "generate":
            selectedTab = .generate
        case "profile":
            selectedTab = .profile
        case "product":
            selectedTab = .shop
            if let list = try? await api.products(query: [URLQueryItem(name: "limit", value: "3")]).value,
               let first = list.items.first {
                pendingProductGID = first.productGid
            }
        case "cart":
            selectedTab = .home
            await prepareDebugCart()
        default:
            break
        }
    }

    private func prepareDebugCart() async {
        do {
            var current = try await ensureCart()
            let wantsThree = ProcessInfo.processInfo.arguments.contains("-cartDemo")
            let target = wantsThree ? 3 : 1
            if current.lines.count < target,
               let list = try? await api.products(query: [URLQueryItem(name: "limit", value: "6")]).value {
                let petID = selectedPet?.petId
                for product in list.items.prefix(target) {
                    let variant = product.variants.first(where: \.availableForSale) ?? product.variants.first
                    guard let variant else { continue }
                    let updated = try await api.addLine(cartID: current.cartId,
                                                        variantGID: variant.variantGid,
                                                        quantity: 1,
                                                        customizationID: petID,
                                                        petID: petID)
                    current = updated.value
                }
                cart = current
            }
            showCart = true
        } catch {
            // Debug helper is best effort.
        }
    }
#endif

    func checkHealth() async {
        do {
            _ = try await api.healthz()
            backendReachable = true
        } catch {
            backendReachable = false
        }
    }

    // MARK: - Auth

    func loginDemoCustomer() async {
        guard !isAuthBusy else { return }
        isAuthBusy = true
        authError = nil
        defer { isAuthBusy = false }
        do {
            let session = try await api.exchangeDemoCustomer().value
            await completeLogin(session)
        } catch {
            authError = (error as? APIError)?.displayMessage(language: language) ?? error.localizedDescription
        }
    }

    func loginGuest() async {
        guard !isAuthBusy else { return }
        isAuthBusy = true
        authError = nil
        defer { isAuthBusy = false }
        do {
            let session = try await api.guestLogin(language: language).value
            await completeLogin(session)
        } catch {
            authError = (error as? APIError)?.displayMessage(language: language) ?? error.localizedDescription
        }
    }

    func claim(code: String) async {
        guard !isAuthBusy else { return }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 6, trimmed.allSatisfy(\.isNumber) else {
            authError = t("login.claimPlaceholder")
            return
        }
        isAuthBusy = true
        authError = nil
        defer { isAuthBusy = false }
        do {
            if accessToken == nil {
                let demoSession = try await api.exchangeDemoCustomer().value
                accessToken = demoSession.accessToken
                api.token = demoSession.accessToken
                Keychain.saveToken(demoSession.accessToken)
            }
            let session = try await api.claim(code: trimmed).value
            await completeLogin(session)
        } catch let apiError as APIError {
            if apiError.code == "CLAIM_CONSUMED" {
                authError = t("error.claimConsumed")
            } else if apiError.code == "CLAIM_INVALID" || apiError.isValidation {
                authError = t("error.claimInvalid")
            } else {
                authError = apiError.displayMessage(language: language)
            }
        } catch {
            authError = error.localizedDescription
        }
    }

    private func completeLogin(_ session: AuthSession) async {
        accessToken = session.accessToken
        api.token = session.accessToken
        Keychain.saveToken(session.accessToken)
        let loginLanguage = language
        do {
            try await refreshMe(applyServerPreferences: true)
        } catch {
            presentError(error)
        }
        // The language explicitly chosen on the sign-in screen wins; sync it to server preferences.
        language = loginLanguage
        if (preferences?.locale ?? "") != loginLanguage {
            await syncPreferences(locale: loginLanguage, theme: nil)
        }
        themePreference = preferences?.themePreference ?? themePreference
        await refreshAppearance()
        await resolveCartIfPossible()
        selectedTab = .home
        showToast(t("login.connectedHint"))
    }

    func logout() async {
        if accessToken != nil {
            try? await api.logout()
        }
        clearLocalSession()
    }

    func clearLocalSession() {
        accessToken = nil
        api.token = nil
        Keychain.deleteToken()
        me = nil
        pets = []
        selectedPetId = nil
        preferences = nil
        cart = nil
        authError = nil
        authEpoch += 1
        selectedTab = .home
        UserDefaults.standard.removeObject(forKey: Self.petKey)
        // Appearance is public and may stay; private caches are dropped above.
    }

    private func handleUnauthorized() {
        guard accessToken != nil else { return }
        clearLocalSession()
        showToast(t("error.unauthorized"), isError: true)
    }

    // MARK: - Me / pets / preferences

    func refreshMe(applyServerPreferences: Bool = false) async throws {
        let result = try await api.me()
        me = result.value
        if let serverProfile = result.value.profile {
            _ = serverProfile
        }
        if let serverPrefs = result.value.preferences {
            preferences = serverPrefs
            if applyServerPreferences {
                if L10n.supported.contains(serverPrefs.locale) {
                    language = serverPrefs.locale
                }
                themePreference = serverPrefs.themePreference
            }
        }
        await loadPets()
    }

    func loadPets() async {
        guard accessToken != nil else { return }
        do {
            let result = try await api.pets(limit: 50)
            pets = result.value.items
            if let me, let profilePets = me.pets, profilePets.count > pets.count {
                pets = profilePets
            }
            if selectedPetId == nil || !pets.contains(where: { $0.petId == selectedPetId }) {
                selectedPetId = pets.first?.petId
                persistSelectedPet()
            }
        } catch let apiError as APIError where apiError.isUnauthorized {
            // handled by client callback
        } catch {
            presentError(error)
        }
    }

    func selectPet(_ pet: Pet) {
        selectedPetId = pet.petId
        persistSelectedPet()
        if let index = pets.firstIndex(where: { $0.petId == pet.petId }) {
            pets[index] = pet
        }
    }

    private func persistSelectedPet() {
        if let selectedPetId {
            UserDefaults.standard.set(selectedPetId, forKey: Self.petKey)
        }
    }

    @discardableResult
    func createPet(name: String, species: String, dogSize: String?, ageMonths: Int?) async -> Pet? {
        do {
            let pet = try await api.createPet(name: name, species: species, dogSize: dogSize, ageMonths: ageMonths).value
            await loadPets()
            selectedPetId = pet.petId
            persistSelectedPet()
            showToast(t("addPet.saved"))
            return pet
        } catch {
            presentError(error)
            return nil
        }
    }

    func refreshProfile() async -> Profile? {
        do {
            let result = try await api.profile()
            return result.value
        } catch {
            presentError(error)
            return nil
        }
    }

    func fetchProfileResult() async throws -> APIResult<Profile> {
        try await api.profile()
    }

    func saveProfile(email: String, fullName: String, etag: String?) async -> Bool {
        do {
            let result = try await api.updateProfile(email: email, fullName: fullName, etag: etag)
            me = (try? await api.me())?.value
            showToast(t("profile.saved"))
            return true
        } catch let apiError as APIError where apiError.isRevisionMismatch {
            showToast(t("profile.conflict"), isError: true)
            return false
        } catch {
            presentError(error)
            return false
        }
    }

    func refreshPreferences() async {
        do {
            preferences = try await api.preferences().value
        } catch {
            presentError(error)
        }
    }

    func setLanguage(_ code: String, syncToServer: Bool = true) async {
        guard L10n.supported.contains(code), code != language else { return }
        language = code
        if syncToServer {
            await syncPreferences(locale: code, theme: nil)
        }
        // Reload localized catalog/recommendation data in views via language change observers.
    }

    func setThemePreference(_ theme: String) async {
        guard ["system", "light", "dark"].contains(theme) else { return }
        themePreference = theme
        await syncPreferences(locale: nil, theme: theme)
    }

    private func syncPreferences(locale: String?, theme: String?) async {
        guard accessToken != nil else { return }
        var etag = preferences?.revision
        if preferences == nil {
            await refreshPreferences()
            etag = preferences?.revision
        }
        do {
            let updated = try await api.updatePreferences(locale: locale, theme: theme, etag: etag)
            preferences = updated.value
        } catch let apiError as APIError where apiError.isRevisionMismatch {
            await refreshPreferences()
            showToast(t("error.conflict"), isError: true)
        } catch let apiError as APIError where apiError.isUnauthorized {
            _ = apiError
        } catch {
            // Preference sync failures should not block local UI.
        }
    }

    // MARK: - Appearance

    func refreshAppearance() async {
        do {
            let result = try await api.appearance(channel: "ios")
            appearance = result.value
        } catch {
            // Built-in fallback theme stays active.
        }
    }

    // MARK: - Cart

    func resolveCartIfPossible() async {
        guard accessToken != nil else { return }
        do {
            let result = try await api.resolveCart()
            cart = result.value
        } catch {
            // Non-fatal: cart view can retry.
        }
    }

    func refreshCart() async {
        guard accessToken != nil else { return }
        if let cartID = cart?.cartId {
            do {
                cart = try await api.cart(id: cartID).value
            } catch {
                await resolveCartIfPossible()
            }
        } else {
            await resolveCartIfPossible()
        }
    }

    func ensureCart() async throws -> Cart {
        if let cart { return cart }
        let result = try await api.resolveCart()
        cart = result.value
        return result.value
    }

    @discardableResult
    func addToCart(product: Product, variant: Variant, petID: String?, quantity: Int) async -> Bool {
        do {
            let cart = try await ensureCart()
            let updated = try await api.addLine(cartID: cart.cartId,
                                               variantGID: variant.variantGid,
                                               quantity: quantity,
                                               customizationID: petID,
                                               petID: petID)
            self.cart = updated.value
            showToast(t("product.added"))
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    // MARK: - Toast / errors

    func showToast(_ text: String, isError: Bool = false) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            toast = ToastMessage(text: text, isError: isError)
        }
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) {
                    self?.toast = nil
                }
            }
        }
    }

    func presentError(_ error: Error) {
        if let apiError = error as? APIError {
            if apiError.isUnauthorized { return }
            if apiError.isValidation {
                if let first = apiError.fieldErrors.first, let message = first.message, !message.isEmpty {
                    showToast("\(first.field): \(message)", isError: true)
                    return
                }
            }
            showToast(apiError.displayMessage(language: language), isError: true)
            return
        }
        showToast(error.localizedDescription, isError: true)
    }

    func presentErrorMessage(_ message: String) {
        showToast(message, isError: true)
    }
}
