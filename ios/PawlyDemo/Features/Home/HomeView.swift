import SwiftUI

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var recommendation: Recommendation?
    @Published var featured: [Product] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var usedFallback = false

    private var loadedKey: String?

    func load(state: AppState, force: Bool = false) async {
        guard state.accessToken != nil else { return }
        let key = "\(state.selectedPet?.petId ?? "none")|\(state.language)"
        if !force, loadedKey == key, !featured.isEmpty { return }
        loadedKey = key
        if featured.isEmpty { isLoading = true }
        errorMessage = nil
        defer { isLoading = false }

        do {
            let query = [URLQueryItem(name: "limit", value: "16"),
                         URLQueryItem(name: "sort", value: "relevance")]
            let products = try await state.api.products(query: query).value.items
            var picks = products.filter { $0.featured == true }
            if picks.isEmpty { picks = Array(products.prefix(6)) }
            featured = picks

            recommendation = nil
            usedFallback = false
            let recommendationID = state.selectedPet?.demoLatestRecommendationId ?? state.me?.resolvedRecommendationId
            if let recommendationID {
                do {
                    let rec = try await state.api.recommendation(id: recommendationID).value
                    recommendation = rec
                } catch {
                    usedFallback = true
                }
            } else {
                usedFallback = true
            }
        } catch {
            errorMessage = (error as? APIError)?.displayMessage(language: state.language) ?? error.localizedDescription
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.pawly) private var theme

    @StateObject private var model = HomeViewModel()
    @State private var selectedProduct: Product?
    @State private var showAddPet = false

    private var refreshKey: String {
        "\(state.selectedPet?.petId ?? "none")|\(state.language)|\(state.me?.resolvedRecommendationId ?? "")"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    petChips

                    if let pet = state.selectedPet {
                        petHero(pet)
                    } else {
                        noPetCard
                    }

                    recommendationSection
                    featuredSection
                    DemoFooter()
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 96)
            }
            .scrollIndicators(.hidden)
            .background(theme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .task(id: refreshKey) {
                await model.load(state: state)
            }
            .refreshable {
                await state.loadPets()
                try? await state.refreshMe(applyServerPreferences: false)
                await model.load(state: state, force: true)
            }
            .sheet(item: $selectedProduct) { product in
                ProductDetailView(product: product)
            }
            .sheet(isPresented: $showAddPet) {
                AddPetSheet()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.t("home.greeting", state.displayName))
                    .font(.system(size: 28, weight: .bold, design: .serif))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(state.t("home.subtitle"))
                    .font(.system(size: 13))
                    .foregroundStyle(theme.muted)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                DemoBadge()
                CartToolbarButton()
            }
            .padding(.top, 2)
        }
    }

    // MARK: - Pet chips

    private var petChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(state.pets) { pet in
                    petChip(pet)
                }
                Button {
                    showAddPet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                        Text(state.t("home.addPet"))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(theme.primary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(theme.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 2)
        }
    }

    private func petChip(_ pet: Pet) -> some View {
        let selected = state.selectedPet?.petId == pet.petId
        return Button {
            state.selectPet(pet)
        } label: {
            HStack(spacing: 7) {
                PetAvatar(urlString: pet.avatarUrl, size: 26, showRing: false)
                Text(pet.name)
                    .font(.system(size: 13, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected ? (theme.isDark ? theme.background : .white) : theme.ink)
                Text(L10n.speciesLabel(pet.species, state.language))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(selected ? (theme.isDark ? theme.background : .white).opacity(0.8) : theme.muted)
            }
            .padding(.leading, 4)
            .padding(.trailing, 12)
            .padding(.vertical, 5)
            .background(selected ? theme.primary : theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.clear : theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Hero card

    private func petHero(_ pet: Pet) -> some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(colors: [theme.primarySoft, theme.accentSoft],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                )

            Image(systemName: "pawprint.fill")
                .font(.system(size: 140))
                .foregroundStyle(theme.primary.opacity(theme.isDark ? 0.1 : 0.09))
                .rotationEffect(.degrees(-12))
                .offset(x: 26, y: -18)

            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 6) {
                        PillLabel(text: L10n.speciesLabel(pet.species, state.language))
                        if let size = pet.dogSize {
                            PillLabel(text: L10n.dogSizeLabel(size, state.language),
                                      tint: theme.accent,
                                      background: theme.surface.opacity(0.75))
                        }
                        if let age = pet.reportedAgeMonths {
                            PillLabel(text: state.t("common.monthsShort", age),
                                      tint: theme.muted,
                                      background: theme.surface.opacity(0.75))
                        }
                    }

                    Text(pet.name)
                        .font(.system(size: 32, weight: .bold, design: .serif))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Text(petSubtitle(pet))
                        .font(.system(size: 12))
                        .foregroundStyle(theme.ink.opacity(0.72))
                        .lineLimit(2)

                    Button {
                        state.selectedTab = .generate
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10, weight: .bold))
                            Text(pet.avatarUrl != nil ? state.t("home.hero.avatarCurrent") : state.t("home.hero.generate"))
                                .font(.system(size: 11, weight: .semibold))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .foregroundStyle(theme.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(theme.surface.opacity(0.8), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)

                PetAvatar(urlString: pet.avatarUrl, size: 96)
            }
            .padding(18)
        }
        .frame(minHeight: 168)
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(theme.surface.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: theme.cardShadow, radius: 16, x: 0, y: 8)
    }

    private func petSubtitle(_ pet: Pet) -> String {
        var parts: [String] = []
        if let breed = pet.breedLabel, !breed.isEmpty {
            parts.append(breed)
        } else {
            parts.append(state.t("home.hero.breedUnknown"))
        }
        if let age = pet.reportedAgeMonths {
            parts.append(state.t("common.months", age))
        }
        if let weight = pet.weightKg {
            parts.append("\(weight) kg")
        }
        return parts.joined(separator: " · ")
    }

    private var noPetCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            EmptyStateView(icon: "pawprint.circle",
                           title: state.t("home.noPets"),
                           hint: state.t("home.noPetsHint"),
                           actionTitle: state.t("home.addPet")) {
                showAddPet = true
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
    }

    // MARK: - Recommendation

    @ViewBuilder
    private var recommendationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: recommendationTitle,
                          subtitle: model.usedFallback ? state.t("home.recommendFallbackNote") : nil)
                .padding(.top, 2)

            if model.isLoading && model.recommendation == nil && model.featured.isEmpty {
                LoadingStateView()
            } else if let error = model.errorMessage, model.featured.isEmpty {
                ErrorStateView(message: error) {
                    Task { await model.load(state: state, force: true) }
                }
            } else if let recommendation = model.recommendation, !recommendation.items.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(recommendation.items.sorted(by: { $0.rank < $1.rank })) { item in
                            RecommendationCard(item: item) {
                                selectedProduct = item.product
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(model.featured.prefix(4)) { product in
                            RecommendationCard(item: RecommendationItem(itemId: product.productGid,
                                                                        rank: 0,
                                                                        reasonCode: nil,
                                                                        reasonText: state.t("home.recommendFallback"),
                                                                        product: product,
                                                                        variantGid: nil)) {
                                selectedProduct = product
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    private var recommendationTitle: String {
        if let pet = state.selectedPet {
            return state.t("home.recommend", pet.name)
        }
        return state.t("home.recommendFallback")
    }

    // MARK: - Featured

    @ViewBuilder
    private var featuredSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: state.t("home.featured"), trailingTitle: state.t("home.viewAll")) {
                state.selectedTab = .shop
            }

            if model.isLoading && model.featured.isEmpty {
                LazyVGrid(columns: gridColumns, spacing: 12) {
                    ForEach(0..<4, id: \.self) { _ in
                        SkeletonCard()
                    }
                }
            } else if !model.featured.isEmpty {
                LazyVGrid(columns: gridColumns, spacing: 12) {
                    ForEach(model.featured.prefix(6)) { product in
                        ProductCard(product: product)
                            .onTapGesture { selectedProduct = product }
                    }
                }
            } else {
                EmptyStateView(icon: "bag", title: state.t("shop.empty"), hint: state.t("shop.emptyHint"))
            }
        }
    }

    private var gridColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }
}

struct SkeletonCard: View {
    @Environment(\.pawly) private var theme
    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
            .fill(theme.surfaceAlt)
            .frame(height: 220)
            .opacity(pulse ? 0.55 : 0.9)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}
