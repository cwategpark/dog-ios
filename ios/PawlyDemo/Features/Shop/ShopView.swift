import SwiftUI

struct ShopQuery: Equatable {
    var search: String = ""
    var audience: String?
    var scene: String?
    var category: String?
    var sort: String = "relevance"

    var key: String {
        "\(search)|\(audience ?? "")|\(scene ?? "")|\(category ?? "")|\(sort)"
    }
}

@MainActor
final class ShopViewModel: ObservableObject {
    @Published var products: [Product] = []
    @Published var nextCursor: String?
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var errorMessage: String?

    private var activeQuery = ShopQuery()
    private var requestID = 0

    func load(state: AppState, query: ShopQuery, reset: Bool = true) async {
        guard state.accessToken != nil else { return }
        if reset { activeQuery = query }
        requestID += 1
        let currentRequest = requestID
        if reset {
            isLoading = true
            errorMessage = nil
        } else {
            guard nextCursor != nil, !isLoadingMore else { return }
            isLoadingMore = true
        }
        defer {
            if currentRequest == requestID {
                isLoading = false
                isLoadingMore = false
            }
        }

        var items: [URLQueryItem] = [URLQueryItem(name: "limit", value: "12")]
        if !activeQuery.search.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append(URLQueryItem(name: "q", value: activeQuery.search.trimmingCharacters(in: .whitespaces)))
        }
        if let audience = activeQuery.audience { items.append(URLQueryItem(name: "audience", value: audience)) }
        if let scene = activeQuery.scene { items.append(URLQueryItem(name: "scene", value: scene)) }
        if let category = activeQuery.category { items.append(URLQueryItem(name: "category", value: category)) }
        items.append(URLQueryItem(name: "sort", value: activeQuery.sort))
        if !reset, let cursor = nextCursor {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }

        do {
            let result = try await state.api.products(query: items)
            guard currentRequest == requestID else { return }
            if reset {
                products = result.value.items
            } else {
                let existing = Set(products.map(\.productGid))
                products.append(contentsOf: result.value.items.filter { !existing.contains($0.productGid) })
            }
            nextCursor = result.value.nextCursor
            errorMessage = nil
        } catch {
            guard currentRequest == requestID else { return }
            errorMessage = (error as? APIError)?.displayMessage(language: state.language) ?? error.localizedDescription
        }
    }
}

struct ShopView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.pawly) private var theme

    @StateObject private var model = ShopViewModel()
    @State private var searchText = ""
    @State private var query = ShopQuery()
    @State private var selectedProduct: Product?
    @State private var sortMenuOpen = false

    private let audiences = ["cat", "dog", "people"]
    private let scenes = ["daily", "outdoor", "travel"]
    private let categories = ["harness", "vest", "collar", "leash", "bed", "bowl", "toy", "bag", "raincoat"]

    private var queryKey: String {
        "\(searchText)|\(query.key)|\(state.language)|\(state.authEpoch)"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                searchBar
                filterBar
                Divider().overlay(theme.border.opacity(0.6))
                content
            }
            .background(theme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .task(id: queryKey) {
                query.search = searchText
                try? await Task.sleep(nanoseconds: 280_000_000)
                guard !Task.isCancelled else { return }
                await model.load(state: state, query: query)
            }
            .task(id: state.pendingProductGID) {
#if DEBUG
                guard let gid = state.pendingProductGID, selectedProduct == nil else { return }
                if let product = try? await state.api.product(productGID: gid).value {
                    selectedProduct = product
                }
#endif
            }
            .sheet(item: $selectedProduct) { product in
                ProductDetailView(product: product)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(state.t("shop.title"))
                    .font(.system(size: 30, weight: .bold, design: .serif))
                    .foregroundStyle(theme.ink)
                Text(state.t("shop.demoNote"))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
            }
            Spacer()
            CartToolbarButton()
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.muted)
                TextField(state.t("shop.search"), text: $searchText)
                    .font(.system(size: 15))
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(theme.muted.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))

            Menu {
                ForEach(["relevance", "price_asc", "price_desc"], id: \.self) { sort in
                    Button {
                        query.sort = sort
                    } label: {
                        if query.sort == sort {
                            Label(state.t("shop.sort.\(sort == "relevance" ? "relevance" : sort == "price_asc" ? "priceAsc" : "priceDesc")"), systemImage: "checkmark")
                        } else {
                            Text(state.t("shop.sort.\(sort == "relevance" ? "relevance" : sort == "price_asc" ? "priceAsc" : "priceDesc")"))
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .frame(width: 42, height: 42)
                    .background(theme.surface, in: Circle())
                    .overlay(Circle().strokeBorder(theme.border, lineWidth: 1))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    // MARK: - Filters

    private var filterBar: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                filterRow(title: state.t("shop.filter.audience"),
                          options: audiences,
                          selected: query.audience,
                          label: { L10n.audienceLabel($0, state.language) }) { value in
                    query.audience = value
                }
                filterRow(title: state.t("shop.filter.scene"),
                          options: scenes,
                          selected: query.scene,
                          label: { L10n.sceneLabel($0, state.language) }) { value in
                    query.scene = value
                }
                filterRow(title: state.t("shop.filter.category"),
                          options: categories,
                          selected: query.category,
                          label: { L10n.categoryLabel($0, state.language) }) { value in
                    query.category = value
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .frame(maxHeight: 128)
    }

    private func filterRow(title: String, options: [String], selected: String?,
                           label: @escaping (String) -> String,
                           onSelect: @escaping (String?) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .frame(width: 54, alignment: .leading)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    SelectableChip(title: state.t("shop.all"), isSelected: selected == nil) {
                        onSelect(nil)
                    }
                    ForEach(options, id: \.self) { option in
                        SelectableChip(title: label(option), isSelected: selected == option) {
                            onSelect(selected == option ? nil : option)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.products.isEmpty {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(0..<6, id: \.self) { _ in SkeletonCard() }
                }
                .padding(16)
            }
        } else if let error = model.errorMessage, model.products.isEmpty {
            ScrollView {
                ErrorStateView(message: error) {
                    Task { await model.load(state: state, query: query) }
                }
                .padding(.top, 40)
            }
        } else if model.products.isEmpty {
            ScrollView {
                EmptyStateView(icon: "magnifyingglass", title: state.t("shop.empty"), hint: state.t("shop.emptyHint"))
                    .padding(.top, 40)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(state.t("shop.count", model.products.count))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.muted)
                        Spacer()
                        Text(state.t("shop.sort.\(query.sort == "relevance" ? "relevance" : query.sort == "price_asc" ? "priceAsc" : "priceDesc")"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.primary)
                    }
                    .padding(.horizontal, 16)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 14) {
                        ForEach(model.products) { product in
                            ProductCard(product: product)
                                .onTapGesture { selectedProduct = product }
                                .onAppear {
                                    if product.productGid == model.products.last?.productGid {
                                        Task { await model.load(state: state, query: query, reset: false) }
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 16)

                    if model.isLoadingMore {
                        ProgressView().tint(theme.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    } else if model.nextCursor == nil {
                        Text(state.t("shop.end"))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }

                    DemoFooter(text: state.t("shop.demoNote"))
                }
                .padding(.top, 12)
                .padding(.bottom, 100)
            }
            .scrollIndicators(.hidden)
        }
    }
}
