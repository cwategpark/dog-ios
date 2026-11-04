import SwiftUI

@MainActor
final class ProfileViewModel: ObservableObject {
    @Published var profile: Profile?
    @Published var profileETag: String?
    @Published var consents: [ConsentItem] = []
    @Published var privacyRequests: [PrivacyRequest] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var privacyBusyKind: String?
    @Published var conflictMessage: String?

    func load(state: AppState) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await state.api.profile()
            profile = result.value
            profileETag = result.etag
            errorMessage = nil
        } catch {
            errorMessage = (error as? APIError)?.displayMessage(language: state.language) ?? error.localizedDescription
        }
        do {
            consents = try await state.api.consents().value.items
        } catch {
            // Non-critical.
        }
    }

    func refreshProfileOnly(state: AppState) async {
        do {
            let result = try await state.api.profile()
            profile = result.value
            profileETag = result.etag
        } catch {
            errorMessage = (error as? APIError)?.displayMessage(language: state.language) ?? error.localizedDescription
        }
    }

    func saveProfile(state: AppState, email: String, fullName: String) async -> Bool {
        conflictMessage = nil
        do {
            let result = try await state.api.updateProfile(email: email, fullName: fullName, etag: profileETag)
            profile = result.value
            profileETag = result.etag
            try? await state.refreshMe(applyServerPreferences: false)
            state.showToast(state.t("profile.saved"))
            return true
        } catch let apiError as APIError where apiError.isRevisionMismatch {
            conflictMessage = state.t("profile.conflict")
            await refreshProfileOnly(state: state)
            return false
        } catch let apiError as APIError where apiError.isValidation {
            if let field = apiError.fieldErrors.first {
                conflictMessage = "\(field.field): \(field.message ?? state.t("error.validation"))"
            } else {
                conflictMessage = apiError.displayMessage(language: state.language)
            }
            return false
        } catch {
            state.presentError(error)
            return false
        }
    }

    func createPrivacyRequest(state: AppState, kind: String) async {
        guard privacyBusyKind == nil else { return }
        privacyBusyKind = kind
        defer { privacyBusyKind = nil }
        do {
            let request = try await state.api.createPrivacyRequest(kind: kind).value
            privacyRequests.insert(request, at: 0)
            state.showToast(state.t("profile.privacy.requested", request.status))
            for _ in 0..<8 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let updated = try? await state.api.privacyRequest(id: request.requestId).value else { continue }
                if let index = privacyRequests.firstIndex(where: { $0.requestId == updated.requestId }) {
                    privacyRequests[index] = updated
                }
                if updated.status == "completed" || updated.status == "failed" { break }
            }
        } catch {
            state.presentError(error)
        }
    }
}

struct ProfileView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.pawly) private var theme

    @StateObject private var model = ProfileViewModel()
    @State private var showEditProfile = false
    @State private var showAddPet = false
    @State private var confirmLogout = false

    private var email: String {
        model.profile?.contactEmail ?? state.me?.profile?.contactEmail ?? "—"
    }

    private var fullName: String {
        model.profile?.fullName ?? state.me?.profile?.fullName ?? "—"
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    pageHeader
                    profileHeader
                    if state.isGuest, let code = state.claimCode {
                        claimCodeCard(code)
                    }
                    petsSection
                    consentsSection
                    preferencesSection
                        .id("settings-section")
                    appearanceSection
                        .id("appearance-section")
                    privacySection
                    demoNotes
                    logoutButton
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 110)
            }
            .scrollIndicators(.hidden)
#if DEBUG
            .task {
                await Task.yield()
                if let scrollTarget = AppState.debugArgument("-profileScroll") {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    withAnimation(.easeInOut(duration: 0.4)) {
                        proxy.scrollTo(scrollTarget == "appearance" ? "appearance-section" : "settings-section", anchor: .top)
                    }
                }
            }
#endif
            .background(theme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .task { await model.load(state: state) }
            .refreshable {
                await model.load(state: state)
                await state.refreshAppearance()
            }
            .sheet(isPresented: $showEditProfile) {
                EditProfileSheet(model: model)
            }
            .sheet(isPresented: $showAddPet) {
                AddPetSheet()
            }
            .confirmationDialog(state.t("profile.logoutConfirm"),
                                isPresented: $confirmLogout,
                                titleVisibility: .visible) {
                Button(state.t("profile.logout"), role: .destructive) {
                    Task { await state.logout() }
                }
                Button(state.t("action.cancel"), role: .cancel) {}
            }
            }
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(state.t("profile.title"))
                    .font(.system(size: 30, weight: .bold, design: .serif))
                    .foregroundStyle(theme.ink)
                Text(state.t("profile.pets.hint"))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
            }
            Spacer()
            CartToolbarButton()
        }
        .padding(.top, 6)
    }

    // MARK: - Header

    private var profileHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [theme.primarySoft, theme.accentSoft],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(initials)
                    .font(.system(size: 24, weight: .bold, design: .serif))
                    .foregroundStyle(theme.ink)
            }
            .frame(width: 64, height: 64)
            .overlay(Circle().strokeBorder(theme.surface, lineWidth: 3))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(fullName)
                        .font(.system(size: 22, weight: .bold, design: .serif))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    DemoBadge()
                }
                Text(email)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    PillLabel(text: subjectKindText,
                              tint: theme.accent,
                              background: theme.accentSoft)
                    if let profile = model.profile {
                        PillLabel(text: state.t("profile.revision", profile.revision),
                                  tint: theme.muted,
                                  background: theme.surfaceAlt)
                    }
                }
            }
            Spacer(minLength: 0)
            Button {
                showEditProfile = true
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .frame(width: 34, height: 34)
                    .background(theme.surface, in: Circle())
                    .overlay(Circle().strokeBorder(theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.t("profile.edit"))
        }
        .pawlyCard(padding: 16)
    }

    private var initials: String {
        let name = model.profile?.fullName ?? state.me?.profile?.fullName ?? ""
        guard let first = name.trimmingCharacters(in: .whitespacesAndNewlines).first else { return "🐾" }
        return String(first)
    }

    private var subjectKindText: String {
        let kind = state.me?.subjectKind ?? "customer"
        return state.t("profile.subject.kind.\(kind)")
    }

    // MARK: - Claim code

    private func claimCodeCard(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "ticket.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.primary)
                Text(state.t("profile.claimCode"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.ink)
                Spacer()
                Text(code)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .tracking(4)
                    .foregroundStyle(theme.primary)
            }
            Text(state.t("home.claimCodeHint"))
                .font(.system(size: 11))
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .pawlyCard(padding: 16)
    }

    // MARK: - Pets

    private var petsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: state.t("profile.pets"),
                          subtitle: state.t("profile.pets.hint"),
                          trailingTitle: state.t("profile.addPet")) {
                showAddPet = true
            }

            if state.pets.isEmpty {
                EmptyStateView(icon: "pawprint.circle",
                               title: state.t("home.noPets"),
                               hint: state.t("home.noPetsHint"),
                               actionTitle: state.t("home.addPet")) {
                    showAddPet = true
                }
                .pawlyCard(padding: 14)
            } else {
                ForEach(state.pets) { pet in
                    petCard(pet)
                }
            }
        }
    }

    private func petCard(_ pet: Pet) -> some View {
        let isCurrent = state.selectedPet?.petId == pet.petId
        return Button {
            state.selectPet(pet)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    PetAvatar(urlString: pet.avatarUrl, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(pet.name)
                                .font(.system(size: 17, weight: .bold, design: .serif))
                                .foregroundStyle(theme.ink)
                            if isCurrent {
                                PillLabel(text: state.t("profile.pet.current"),
                                          tint: theme.primary,
                                          background: theme.primarySoft)
                            }
                        }
                        Text(petMeta(pet))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.muted)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.muted.opacity(0.6))
                }

                if hasMeasurements(pet) {
                    HStack(spacing: 8) {
                        if let neck = pet.neckCm {
                            measurementChip(state.t("profile.pet.neck"), "\(neck) cm")
                        }
                        if let chest = pet.chestCm {
                            measurementChip(state.t("profile.pet.chest"), "\(chest) cm")
                        }
                        if let back = pet.backLengthCm {
                            measurementChip(state.t("profile.pet.back"), "\(back) cm")
                        }
                        if let weight = pet.weightKg {
                            measurementChip(state.t("profile.pet.weight"), "\(weight) kg")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .pawlyCard(padding: 14)
        }
        .buttonStyle(.plain)
    }

    private func petMeta(_ pet: Pet) -> String {
        var parts: [String] = [L10n.speciesLabel(pet.species, state.language)]
        if let breed = pet.breedLabel, !breed.isEmpty {
            parts.append(breed)
        }
        if let size = pet.dogSize {
            parts.append(L10n.dogSizeLabel(size, state.language))
        }
        if let age = pet.reportedAgeMonths {
            parts.append(state.t("profile.pet.age", age))
        }
        return parts.joined(separator: " · ")
    }

    private func hasMeasurements(_ pet: Pet) -> Bool {
        pet.neckCm != nil || pet.chestCm != nil || pet.backLengthCm != nil || pet.weightKg != nil
    }

    private func measurementChip(_ title: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(theme.muted)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.ink)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: - Consents

    private var consentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: state.t("profile.consents"))

            if model.consents.isEmpty {
                Text(state.t("profile.consents.empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 14)
                    .pawlyCard(padding: 14)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.consents.enumerated()), id: \.element.consentEventId) { index, consent in
                        HStack(spacing: 8) {
                            Image(systemName: consent.granted ? "checkmark.shield.fill" : "xmark.shield.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(consent.granted ? theme.success : theme.muted)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.scopeLabel(consent.scope, state.language))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(theme.ink)
                                Text(ProfileView.shortDate(consent.occurredAt))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(theme.muted)
                            }
                            Spacer()
                            PillLabel(text: consent.granted ? state.t("profile.consents.granted") : state.t("profile.consents.withdrawn"),
                                      tint: consent.granted ? theme.success : theme.muted,
                                      background: consent.granted ? theme.accentSoft : theme.surfaceAlt)
                        }
                        .padding(.vertical, 10)
                        if index < model.consents.count - 1 {
                            Divider().overlay(theme.border.opacity(0.6))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                        .strokeBorder(theme.border, lineWidth: 1)
                )
            }
        }
    }

    // MARK: - Preferences

    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: state.t("profile.preferences"))

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(state.t("profile.language"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.muted)
                    HStack(spacing: 8) {
                        ForEach(L10n.supported, id: \.self) { code in
                            SelectableChip(title: languageName(code), isSelected: state.language == code) {
                                Task { await state.setLanguage(code) }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text(state.t("profile.theme"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.muted)
                    HStack(spacing: 8) {
                        ForEach(["system", "light", "dark"], id: \.self) { mode in
                            SelectableChip(title: L10n.themeLabel(mode, state.language),
                                           isSelected: state.themePreference == mode) {
                                Task { await state.setThemePreference(mode) }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .pawlyCard(padding: 16)
        }
    }

    private func languageName(_ code: String) -> String {
        switch code {
        case "zh-CN": return "中文"
        case "es": return "Español"
        case "en": return "English"
        default: return code
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: state.t("profile.appearance"),
                          trailingTitle: state.t("profile.appearance.reload")) {
                Task {
                    await state.refreshAppearance()
                    state.showToast(state.t("profile.appearance.loaded"))
                }
            }

            VStack(spacing: 0) {
                appearanceRow(state.t("profile.appearance.release"), state.appearanceReleaseShort)
                Divider().overlay(theme.border.opacity(0.6))
                appearanceRow(state.t("profile.appearance.revision"), state.appearance?.headRevision ?? "—")
                Divider().overlay(theme.border.opacity(0.6))
                appearanceRow(state.t("profile.appearance.renderer"), state.appearance?.rendererKey ?? "—")
                Divider().overlay(theme.border.opacity(0.6))
                appearanceRow(state.t("profile.appearance.channel"), "ios")
            }
            .padding(.horizontal, 14)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1)
            )
        }
    }

    private func appearanceRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(theme.muted)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.ink)
        }
        .padding(.vertical, 10)
    }

    // MARK: - Privacy

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: state.t("profile.privacy"))

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    privacyButton(kind: "data_export",
                                  title: state.t("profile.privacy.export"),
                                  systemImage: "square.and.arrow.down")
                    privacyButton(kind: "account_delete",
                                  title: state.t("profile.privacy.delete"),
                                  systemImage: "person.crop.circle.badge.xmark")
                }

                if !model.privacyRequests.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(model.privacyRequests) { request in
                            HStack(spacing: 6) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 10))
                                    .foregroundStyle(theme.muted)
                                Text(request.kind == "data_export" ? state.t("profile.privacy.export") : state.t("profile.privacy.delete"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.ink)
                                Spacer()
                                PillLabel(text: L10n.privacyStatusLabel(request.status, state.language),
                                          tint: request.status == "completed" ? theme.success : theme.primary,
                                          background: request.status == "completed" ? theme.accentSoft : theme.primarySoft)
                            }
                        }
                    }
                }

                Text(state.t("profile.privacy.note"))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .pawlyCard(padding: 14)
        }
    }

    private func privacyButton(kind: String, title: String, systemImage: String) -> some View {
        Button {
            Task { await model.createPrivacyRequest(state: state, kind: kind) }
        } label: {
            HStack(spacing: 6) {
                if model.privacyBusyKind == kind {
                    ProgressView().tint(theme.ink)
                } else {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .padding(.horizontal, 8)
            .background(theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(model.privacyBusyKind != nil)
    }

    // MARK: - Demo notes / logout

    private var demoNotes: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.primary)
                Text(state.t("profile.demoEnv"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.ink)
                Spacer()
                DemoBadge()
            }
            Text(state.t("profile.demoEnvText"))
                .font(.system(size: 11))
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(state.t("profile.appVersion")) \(state.appVersion)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.muted.opacity(0.7))
                .padding(.top, 2)
        }
        .pawlyCard(padding: 14)
    }

    private var logoutButton: some View {
        Button {
            confirmLogout = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.right.square")
                Text(state.t("profile.logout"))
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(theme.danger)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(theme.danger.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    static func shortDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: iso)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: iso)
        }
        guard let date else { return iso }
        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .short
        return display.string(from: date)
    }
}

// MARK: - Edit profile sheet

struct EditProfileSheet: View {
    @ObservedObject var model: ProfileViewModel

    @EnvironmentObject private var state: AppState
    @Environment(\.pawly) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var fullName = ""
    @State private var isSaving = false
    @State private var localError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field(title: state.t("profile.name"), placeholder: "", text: $fullName, keyboard: .default)
                    field(title: state.t("profile.email"), placeholder: "demo@pawly.invalid", text: $email, keyboard: .emailAddress)

                    if model.profile?.contactEmailVerifiedAt == nil {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle")
                                .font(.system(size: 11))
                            Text(state.t("profile.notVerified"))
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(theme.muted)
                    }

                    if let message = model.conflictMessage ?? localError {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.danger)
                                .padding(.top, 1)
                            Text(message)
                                .font(.system(size: 12))
                                .foregroundStyle(theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .background(theme.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    Text("PATCH /v1/me/profile · If-Match \(model.profileETag ?? "—")")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.muted.opacity(0.7))
                        .lineLimit(2)

                    Button {
                        Task { await save() }
                    } label: {
                        HStack(spacing: 8) {
                            if isSaving { ProgressView().tint(theme.isDark ? theme.background : .white) }
                            Text(isSaving ? state.t("profile.saving") : state.t("profile.save"))
                        }
                    }
                    .buttonStyle(PawlyPrimaryButtonStyle(enabled: !isSaving))
                    .disabled(isSaving)
                }
                .padding(20)
            }
            .background(theme.background)
            .navigationTitle(state.t("profile.account"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(state.t("action.cancel")) { dismiss() }
                        .foregroundStyle(theme.muted)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            email = model.profile?.contactEmail ?? ""
            fullName = model.profile?.fullName ?? ""
        }
    }

    private func field(title: String, placeholder: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.muted)
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(keyboard == .emailAddress ? .never : .words)
                .autocorrectionDisabled(keyboard == .emailAddress)
                .font(.system(size: 16))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func save() async {
        let trimmedName = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedEmail.isEmpty else {
            localError = state.t("error.required")
            return
        }
        localError = nil
        isSaving = true
        defer { isSaving = false }
        let success = await model.saveProfile(state: state, email: trimmedEmail, fullName: trimmedName)
        if success {
            dismiss()
        }
    }
}
