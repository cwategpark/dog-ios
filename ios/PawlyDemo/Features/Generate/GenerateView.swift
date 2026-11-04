import SwiftUI
import CryptoKit
import PhotosUI
import UIKit

// MARK: - Sample photos

enum SamplePhoto: String, CaseIterable, Identifiable {
    case cat
    case dog

    var id: String { rawValue }

    var filename: String {
        self == .cat ? "photo-cat" : "photo-dog"
    }

    var titleKey: String {
        self == .cat ? "generate.photo.cat" : "generate.photo.dog"
    }

    var data: Data? {
        if let url = Bundle.main.url(forResource: filename, withExtension: "jpg"),
           let data = try? Data(contentsOf: url) {
            return data
        }
        return nil
    }

    var image: UIImage? {
        if let url = Bundle.main.url(forResource: filename, withExtension: "jpg") {
            return UIImage(contentsOfFile: url.path)
        }
        return UIImage(named: filename)
    }

    var species: String { self == .cat ? "cat" : "dog" }
}

enum GenerationPhase: Equatable {
    case idle
    case uploading
    case completing
    case creating
    case polling
    case succeeded
    case failed
}

// MARK: - View model

@MainActor
final class GenerateViewModel: ObservableObject {
    @Published var templates: [GenerationTemplate] = []
    @Published var history: [GenerationJob] = []
    @Published var job: GenerationJob?
    @Published var phase: GenerationPhase = .idle
    @Published var statusLine: String?
    @Published var posterURL: String?
    @Published var errorMessage: String?
    @Published var isSubmitting = false
    @Published var isLoadingHistory = false
    @Published var isCancelling = false

    private var pollTask: Task<Void, Never>?
    private var templatesLoaded = false

    func loadTemplates(state: AppState) async {
        guard !templatesLoaded else { return }
        do {
            templates = try await state.api.templates().value.items
            templatesLoaded = true
        } catch {
            templatesLoaded = false
        }
    }

    func loadHistory(state: AppState) async {
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            history = try await state.api.generationJobs(limit: 20).value.items
            if job == nil, let active = history.first(where: { !$0.isTerminal }) {
                job = active
                phase = .polling
                startPolling(state: state, jobID: active.jobId)
            }
        } catch let apiError as APIError where apiError.isUnauthorized {
            // global handler
        } catch {
            // History is non-critical.
        }
    }

    func submit(state: AppState, pet: Pet, imageData: Data, photoConsent: Bool, modelConsent: Bool) async {
        guard !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        pollTask?.cancel()
        job = nil
        posterURL = nil
        errorMessage = nil
        statusLine = nil
        phase = .uploading

        do {
            // Consent events must exist (granted) before any photo upload / job creation.
            let consentIDs = try await ensureConsentEvents(state: state,
                                                           photoConsent: photoConsent,
                                                           modelConsent: modelConsent)

            statusLine = state.t("generate.uploading")
            let digest = SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined()
            let ticket = try await state.api.createUpload(petID: pet.petId,
                                                          mimeType: "image/jpeg",
                                                          byteSize: imageData.count,
                                                          sha256: digest).value
            try await state.api.putUpload(ticket: ticket, data: imageData)

            statusLine = state.t("generate.completing")
            phase = .completing
            let completed = try await state.api.completeUpload(uploadID: ticket.uploadId).value
            let assetID = completed.asset.assetId

            statusLine = state.t("generate.creating")
            phase = .creating
            await loadTemplates(state: state)
            guard let template = templates.first(where: { $0.species == pet.species }) ?? templates.first else {
                throw APIError.unexpected(state.t("generate.noTemplate"))
            }
            let created = try await state.api.createGenerationJob(petID: pet.petId,
                                                                  sourceAssetIDs: [assetID],
                                                                  method: "template_personalization",
                                                                  templateVersionID: template.templateVersionId,
                                                                  consentEventIDs: consentIDs).value
            job = created
            phase = .polling
            startPolling(state: state, jobID: created.jobId)
        } catch {
            phase = .failed
            errorMessage = (error as? APIError)?.displayMessage(language: state.language)
                ?? error.localizedDescription
            state.presentError(error)
        }
    }

    private func ensureConsentEvents(state: AppState, photoConsent: Bool, modelConsent: Bool) async throws -> [String] {
        let existing = try await state.api.consents().value.items
        let scopes = ["photo_processing", "model_generation"]
        var ids: [String] = []
        for scope in scopes {
            if let event = existing.last(where: { $0.scope == scope && $0.granted }) {
                ids.append(event.consentEventId)
            }
        }
        if ids.count == scopes.count { return ids }

        let items: [[String: Any]] = [
            ["scope": "photo_processing", "granted": photoConsent, "policy_version": "photo-v1"],
            ["scope": "model_generation", "granted": modelConsent, "policy_version": "model-v1"]
        ]
        let created = try await state.api.createConsents(items).value.items
        var createdIDs: [String] = []
        for scope in scopes {
            if let event = created.last(where: { $0.scope == scope }) {
                createdIDs.append(event.consentEventId)
            }
        }
        if createdIDs.count == scopes.count { return createdIDs }
        return ids.isEmpty ? created.map(\.consentEventId) : ids
    }

    private func startPolling(state: AppState, jobID: String) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.poll(state: state, jobID: jobID)
        }
    }

    private func poll(state: AppState, jobID: String) async {
        for _ in 0..<120 {
            if Task.isCancelled { return }
            do {
                let latest = try await state.api.generationJob(id: jobID).value
                guard !Task.isCancelled else { return }
                job = latest
                if latest.status == "succeeded" {
                    phase = .succeeded
                    statusLine = nil
                    if let poster = latest.output(role: "poster") {
                        if let url = poster.accessUrl {
                            posterURL = url
                        } else if poster.state == "ready",
                                  let access = try? await state.api.assetAccess(assetID: poster.assetId).value {
                            posterURL = access.url
                        }
                    }
                    await state.loadPets()
                    await loadHistory(state: state)
                    state.showToast(state.t("generate.avatarUpdated"))
                    return
                }
                if latest.status == "failed" || latest.status == "cancelled" {
                    phase = .failed
                    statusLine = nil
                    if let errorCode = latest.errorCode {
                        errorMessage = "\(errorCode)"
                    }
                    return
                }
                phase = .polling
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch let apiError as APIError where apiError.isUnauthorized {
                return
            } catch {
                // Keep polling on transient network failures.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    func cancel(state: AppState) async {
        guard let job, !job.isTerminal else { return }
        isCancelling = true
        defer { isCancelling = false }
        do {
            let updated = try await state.api.cancelGenerationJob(id: job.jobId).value
            self.job = updated
            state.showToast(state.t("generate.cancelled"))
            await loadHistory(state: state)
        } catch {
            state.presentError(error)
        }
    }

    func reset() {
        pollTask?.cancel()
        job = nil
        posterURL = nil
        phase = .idle
        statusLine = nil
        errorMessage = nil
    }

    func stopPolling() {
        pollTask?.cancel()
    }
}

// MARK: - View

struct GenerateView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.pawly) private var theme

    @StateObject private var model = GenerateViewModel()
    @State private var selectedSample: SamplePhoto? = .cat
    @State private var libraryItem: PhotosPickerItem?
    @State private var libraryData: Data?
    @State private var photoConsent = true
    @State private var modelConsent = true
    @State private var showAddPet = false

    private var pet: Pet? { state.selectedPet }

    private var selectedImageData: Data? {
        if let libraryData { return libraryData }
        return selectedSample?.data
    }

    private var canSubmit: Bool {
        pet != nil && selectedImageData != nil && photoConsent && modelConsent && !model.isSubmitting
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    petStep
                    photoStep
                    consentStep
                    submitButton
                    if model.phase != .idle {
                        jobSection
                            .id("job-section")
                    }
                    historySection
                        .id("history-section")
                    DemoFooter()
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.phase) { _, phase in
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-runGenerate"),
                   phase == .polling || phase == .succeeded || phase == .uploading {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        proxy.scrollTo("job-section", anchor: .top)
                    }
                }
#endif
            }
            .background(theme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { CartToolbarButton() }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .task {
                await model.loadTemplates(state: state)
                await model.loadHistory(state: state)
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-runGenerate") {
                    for _ in 0..<40 {
                        if state.selectedPet != nil { break }
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                    if let pet = state.selectedPet, let data = SamplePhoto.cat.data {
                        await model.submit(state: state, pet: pet, imageData: data,
                                           photoConsent: true, modelConsent: true)
                        for _ in 0..<40 where model.phase != .succeeded {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                        }
                    }
                }
#endif
            }
            .sheet(isPresented: $showAddPet) { AddPetSheet() }
            .onChange(of: libraryItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        libraryData = data
                        selectedSample = nil
                    }
                }
            }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.t("generate.title"))
                        .font(.system(size: 28, weight: .bold, design: .serif))
                        .foregroundStyle(theme.ink)
                    Text(state.t("generate.subtitle"))
                        .font(.system(size: 12))
                        .foregroundStyle(theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                DemoBadge()
            }
        }
    }

    // MARK: - Step 1: pet

    private var petStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle(state.t("generate.step.pet"), index: 1)

            if state.pets.isEmpty {
                EmptyStateView(icon: "pawprint.circle",
                               title: state.t("home.noPets"),
                               hint: state.t("home.noPetsHint"),
                               actionTitle: state.t("home.addPet")) {
                    showAddPet = true
                }
                .padding(.vertical, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(state.pets) { candidate in
                            let selected = pet?.petId == candidate.petId
                            Button {
                                state.selectPet(candidate)
                            } label: {
                                HStack(spacing: 8) {
                                    PetAvatar(urlString: candidate.avatarUrl, size: 32, showRing: false)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.name)
                                            .font(.system(size: 14, weight: selected ? .bold : .medium))
                                            .foregroundStyle(selected ? (theme.isDark ? theme.background : .white) : theme.ink)
                                        Text(L10n.speciesLabel(candidate.species, state.language))
                                            .font(.system(size: 10))
                                            .foregroundStyle(selected ? (theme.isDark ? theme.background : .white).opacity(0.8) : theme.muted)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(selected ? theme.primary : theme.surface, in: Capsule())
                                .overlay(Capsule().strokeBorder(selected ? Color.clear : theme.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                        Button {
                            showAddPet = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(theme.primary)
                                .frame(width: 38, height: 38)
                                .background(theme.surface, in: Circle())
                                .overlay(Circle().strokeBorder(theme.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .pawlyCard(padding: 16)
    }

    // MARK: - Step 2: photo

    private var photoStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle(state.t("generate.step.photo"), index: 2)

            HStack(spacing: 10) {
                ForEach(SamplePhoto.allCases) { sample in
                    sampleThumbnail(sample)
                }
                PhotosPicker(selection: $libraryItem, matching: .images) {
                    VStack(spacing: 6) {
                        if let libraryData, let image = UIImage(data: libraryData) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 96, height: 76)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        } else {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 20))
                                .foregroundStyle(theme.primary)
                                .frame(width: 96, height: 56)
                        }
                        Text(state.t("action.fromLibrary"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.muted)
                    }
                    .frame(width: 96, height: 100)
                    .background(theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(selectedSample == nil ? theme.primary : theme.border,
                                          lineWidth: selectedSample == nil && libraryData != nil ? 2 : 1)
                    )
                }
            }

            Text(state.t("generate.photo.hint"))
                .font(.system(size: 10))
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .pawlyCard(padding: 16)
    }

    private func sampleThumbnail(_ sample: SamplePhoto) -> some View {
        let selected = selectedSample == sample && libraryData == nil
        return Button {
            selectedSample = sample
            libraryData = nil
            libraryItem = nil
        } label: {
            VStack(spacing: 6) {
                if let image = sample.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 96, height: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 20))
                        .frame(width: 96, height: 76)
                }
                Text(state.t(sample.titleKey))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(selected ? theme.primary : theme.muted)
            }
            .frame(width: 96, height: 100)
            .background(theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(selected ? theme.primary : theme.border, lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 3: consent

    private var consentStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle(state.t("generate.step.consent"), index: 3)

            consentToggle(title: state.t("generate.consent.photo"), isOn: $photoConsent)
            consentToggle(title: state.t("generate.consent.model"), isOn: $modelConsent)

            Text(state.t("generate.consentHint"))
                .font(.system(size: 10))
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .pawlyCard(padding: 16)
    }

    private func consentToggle(title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.system(size: 19))
                    .foregroundStyle(isOn.wrappedValue ? theme.primary : theme.muted)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Submit

    private var submitButton: some View {
        VStack(spacing: 8) {
            Button {
                Task { await submit() }
            } label: {
                HStack(spacing: 8) {
                    if model.isSubmitting {
                        ProgressView().tint(theme.isDark ? theme.background : .white)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(model.isSubmitting ? (model.statusLine ?? state.t("generate.submitting")) : state.t("generate.submit"))
                }
            }
            .buttonStyle(PawlyPrimaryButtonStyle(enabled: canSubmit))
            .disabled(!canSubmit)

            if !photoConsent || !modelConsent {
                Text(state.t("generate.error.consent"))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.danger)
            }
        }
    }

    private func submit() async {
        guard let pet, let data = selectedImageData else { return }
        await model.submit(state: state, pet: pet, imageData: data, photoConsent: photoConsent, modelConsent: modelConsent)
    }

    // MARK: - Job

    @ViewBuilder
    private var jobSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.phase == .succeeded ? state.t("generate.successTitle") : state.t("generate.resultTitle"))
                    .font(.system(size: 18, weight: .bold, design: .serif))
                    .foregroundStyle(theme.ink)
                Spacer()
                if let job = model.job {
                    statusPill(job.status)
                }
            }

            if let job = model.job, !job.isTerminal {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: iconName(for: job.status))
                            .foregroundStyle(jobColor(job.status))
                        Text(L10n.statusLabel(job.status, state.language))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.ink)
                        Spacer()
                        Text(state.t("generate.stage") + " · " + L10n.stageLabel(job.stage, state.language))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.muted)
                    }

                    if let progress = job.progress {
                        ProgressView(value: Double(progress), total: 100)
                            .tint(theme.primary)
                        Text("\(progress)%")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.muted)
                    } else {
                        ProgressView()
                            .tint(theme.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        Task { await model.cancel(state: state) }
                    } label: {
                        HStack(spacing: 6) {
                            if model.isCancelling {
                                ProgressView().tint(theme.danger)
                            }
                            Text(state.t("generate.cancel"))
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.danger)
                }
            }

            if let job = model.job, job.isTerminal, job.status != "succeeded" {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.danger)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.statusLabel(job.status, state.language))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.ink)
                        if let errorCode = job.errorCode {
                            Text(errorCode)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(theme.muted)
                        }
                        if let error = model.errorMessage {
                            Text(error)
                                .font(.system(size: 11))
                                .foregroundStyle(theme.danger)
                        }
                    }
                }
            }

            if model.phase == .succeeded, let job = model.job {
                successBlock(job)
            }
        }
        .pawlyCard(padding: 16)
    }

    private func successBlock(_ job: GenerationJob) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().overlay(theme.border.opacity(0.6))

            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(theme.success)
                Text(state.t("generate.succeeded"))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(theme.ink)
            }

            if let posterURL = model.posterURL {
                RemoteImage(urlString: posterURL, cornerRadius: 18)
                    .frame(height: 220)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .overlay(alignment: .bottomTrailing) {
                        HStack(spacing: 4) {
                            Image(systemName: "photo")
                            Text(state.t("generate.poster"))
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.45), in: Capsule())
                        .padding(8)
                    }
            }

            outputRow(role: "glb", title: state.t("generate.glb"), job: job)
            outputRow(role: "manifest", title: state.t("generate.manifest"), job: job)
            outputRow(role: "usdz", title: state.t("generate.usdz"), job: job)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.primary)
                    .padding(.top, 1)
                Text(state.t("generate.downgrade"))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(theme.primarySoft.opacity(theme.isDark ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button {
                model.reset()
            } label: {
                Text(state.t("generate.retry"))
            }
            .buttonStyle(PawlySecondaryButtonStyle())
        }
    }

    private func outputRow(role: String, title: String, job: GenerationJob) -> some View {
        let output = job.output(role: role)
        let ready = output?.state == "ready"
        return HStack(spacing: 8) {
            Image(systemName: ready ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(ready ? theme.success : theme.muted)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(theme.ink)
            Spacer()
            Text(ready ? state.t("generate.ready") : state.t("generate.failed"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ready ? theme.success : theme.muted)
        }
    }

    private func statusPill(_ status: String) -> some View {
        PillLabel(text: L10n.statusLabel(status, state.language),
                  tint: jobColor(status),
                  background: jobColor(status).opacity(0.14))
    }

    private func jobColor(_ status: String) -> Color {
        switch status {
        case "succeeded": return theme.success
        case "failed", "cancelled": return theme.danger
        default: return theme.primary
        }
    }

    private func iconName(for status: String) -> String {
        switch status {
        case "succeeded": return "checkmark.seal.fill"
        case "failed", "cancelled": return "xmark.octagon.fill"
        default: return "sparkles"
        }
    }

    // MARK: - History

    @ViewBuilder
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: state.t("generate.history"))

            if model.isLoadingHistory && model.history.isEmpty {
                LoadingStateView()
            } else if model.history.isEmpty {
                Text(state.t("generate.historyEmpty"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.history.enumerated()), id: \.element.jobId) { index, job in
                        Button {
                            model.job = job
                            model.phase = job.status == "succeeded" ? .succeeded : (job.isTerminal ? .failed : .polling)
                            model.errorMessage = nil
                            if job.status == "succeeded", let poster = job.output(role: "poster") {
                                model.posterURL = poster.accessUrl
                            } else {
                                model.posterURL = nil
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: iconName(for: job.status))
                                    .font(.system(size: 13))
                                    .foregroundStyle(jobColor(job.status))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(state.pet(withID: job.petId)?.name ?? job.petId)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(theme.ink)
                                    Text(job.isTerminal
                                         ? L10n.statusLabel(job.status, state.language)
                                         : L10n.stageLabel(job.stage, state.language) + " · " + L10n.statusLabel(job.status, state.language))
                                        .font(.system(size: 10))
                                        .foregroundStyle(theme.muted)
                                }
                                Spacer()
                                Text(Self.shortDate(job.updatedAt ?? job.createdAt))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(theme.muted)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(theme.muted.opacity(0.6))
                            }
                            .padding(.vertical, 11)
                        }
                        .buttonStyle(.plain)
                        if index < model.history.count - 1 {
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

    private func stepTitle(_ title: String, index: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(index)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(theme.isDark ? theme.background : .white)
                .frame(width: 20, height: 20)
                .background(theme.primary, in: Circle())
            Text(title)
                .font(.system(size: 15, weight: .bold, design: .serif))
                .foregroundStyle(theme.ink)
        }
    }

    static func shortDate(_ iso: String?) -> String {
        guard let iso else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: iso)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: iso)
        }
        guard let date else { return "" }
        let display = DateFormatter()
        display.dateFormat = "MM-dd HH:mm"
        return display.string(from: date)
    }
}
