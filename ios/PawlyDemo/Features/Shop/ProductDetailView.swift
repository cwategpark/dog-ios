import SwiftUI

private struct OptionGroup: Identifiable {
    let name: String
    let label: String
    let values: [OptionValue]
    var id: String { name }
}

private struct OptionValue: Identifiable {
    let value: String
    let label: String
    var id: String { value }
}

@MainActor
final class ProductDetailViewModel: ObservableObject {
    @Published var product: Product
    @Published var isLoading = false
    @Published var errorMessage: String?

    init(product: Product) {
        self.product = product
    }

    func refresh(state: AppState) async {
        isLoading = true
        defer { isLoading = false }
        do {
            product = try await state.api.product(productGID: product.productGid).value
        } catch {
            if let apiError = error as? APIError, !apiError.isUnauthorized {
                errorMessage = apiError.displayMessage(language: state.language)
            }
        }
    }
}

struct ProductDetailView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.pawly) private var theme
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model: ProductDetailViewModel
    @State private var selection: [String: String] = [:]
    @State private var quantity = 1
    @State private var isAdding = false
    @State private var added = false
    @State private var galleryIndex = 0
    @State private var hasLoaded = false

    init(product: Product) {
        _model = StateObject(wrappedValue: ProductDetailViewModel(product: product))
    }

    private var product: Product { model.product }

    private var groups: [OptionGroup] {
        if let options = product.options, !options.isEmpty {
            return options.map { option in
                OptionGroup(name: option.name,
                            label: option.displayName(language: state.language),
                            values: option.values.map { OptionValue(value: $0.value,
                                                                   label: $0.displayLabel(language: state.language)) })
            }
        }
        var order: [String] = []
        var valueMap: [String: [(String, String)]] = [:]
        for variant in product.variants {
            for option in variant.selectedOptions {
                if valueMap[option.name] == nil {
                    order.append(option.name)
                    valueMap[option.name] = []
                }
                if !(valueMap[option.name]?.contains(where: { $0.0 == option.value }) ?? false) {
                    valueMap[option.name]?.append((option.value, option.displayLabel(language: state.language)))
                }
            }
        }
        return order.map { name in
            OptionGroup(name: name,
                        label: L10n.optionNameLabel(name, state.language),
                        values: (valueMap[name] ?? []).map { OptionValue(value: $0.0, label: $0.1) })
        }
    }

    private var selectedVariant: Variant? {
        guard !groups.isEmpty else { return product.variants.first }
        guard selection.count == groups.count else { return nil }
        return product.variants.first { variant in
            groups.allSatisfy { group in
                variant.selectedOptions.contains { $0.name == group.name && $0.value == selection[group.name] }
            }
        }
    }

    private var displayedPrice: Money? {
        selectedVariant?.price ?? product.priceRange
    }

    private var canAdd: Bool {
        guard let variant = selectedVariant else { return false }
        return variant.availableForSale && !isAdding && state.accessToken != nil
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    gallery
                    headerBlock
                    if let fit = product.fitSummary?.text(language: state.language), !fit.isEmpty {
                        fitBlock(fit)
                    }
                    descriptionBlock
                    if !groups.isEmpty {
                        optionsBlock
                            .id("options-section")
                    }
                    capabilitiesBlock
                        .id("caps-section")
                    DemoFooter(text: state.t("product.demoNote"))
                }
                .padding(.bottom, 120)
            }
            .scrollIndicators(.hidden)
            .background(theme.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { addBar }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(theme.ink)
                            .frame(width: 32, height: 32)
                            .background(theme.surface, in: Circle())
                            .overlay(Circle().strokeBorder(theme.border, lineWidth: 1))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { CartToolbarButton() }
            }
            .task {
                guard !hasLoaded else { return }
                hasLoaded = true
                await model.refresh(state: state)
                preselect()
#if DEBUG
                if let target = AppState.debugArgument("-productScroll") {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    withAnimation(.easeInOut(duration: 0.4)) {
                        proxy.scrollTo(target == "caps" ? "caps-section" : "options-section", anchor: .top)
                    }
                }
#endif
            }
            .onChange(of: product.productGid) { _, _ in preselect() }
            .onChange(of: state.language) { _, _ in
                Task {
                    await model.refresh(state: state)
                    preselect()
                }
            }
            }
        }
    }

    // MARK: - Gallery

    private var gallery: some View {
        ZStack(alignment: .topLeading) {
            TabView(selection: $galleryIndex) {
                if product.images.isEmpty {
                    RemoteImage(urlString: product.primaryImageURL, cornerRadius: 0)
                        .tag(0)
                } else {
                    ForEach(Array(product.images.enumerated()), id: \.offset) { index, media in
                        RemoteImage(urlString: media.url, contentMode: .fill, cornerRadius: 0)
                            .tag(index)
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 340)

            HStack(spacing: 6) {
                if let badge = product.badge?.text(language: state.language), !badge.isEmpty {
                    PillLabel(text: badge)
                }
                if product.capabilities?.has3D == true {
                    HStack(spacing: 4) {
                        Image(systemName: "cube.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text(state.t("product.badge3d"))
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(theme.ink)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(theme.surface.opacity(0.9), in: Capsule())
                }
            }
            .padding(14)

            if product.images.count > 1 {
                HStack(spacing: 5) {
                    ForEach(0..<product.images.count, id: \.self) { index in
                        Capsule()
                            .fill(index == galleryIndex ? theme.primary : theme.surface.opacity(0.7))
                            .frame(width: index == galleryIndex ? 16 : 6, height: 6)
                    }
                }
                .padding(12)
                .background(theme.surface.opacity(0.55), in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 12)
            }
        }
        .frame(height: 340)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    // MARK: - Header / price

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let audience = product.audienceCodes?.first {
                    PillLabel(text: L10n.audienceLabel(audience, state.language),
                              tint: theme.accent,
                              background: theme.accentSoft)
                }
                if let category = product.categoryCodes?.first {
                    PillLabel(text: L10n.categoryLabel(category, state.language),
                              tint: theme.muted,
                              background: theme.surfaceAlt)
                }
            }

            Text(product.title)
                .font(.system(size: 27, weight: .bold, design: .serif))
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let price = displayedPrice {
                    PriceLabel(money: price, compareAt: selectedVariant?.compareAtPrice, large: true)
                }
                if product.hasPriceRange && selectedVariant == nil {
                    Text(state.t("product.from"))
                        .font(.system(size: 12))
                        .foregroundStyle(theme.muted)
                }
                Spacer()
                if product.isAvailable {
                    HStack(spacing: 4) {
                        Circle().fill(theme.success).frame(width: 6, height: 6)
                        Text("\(product.variants.filter(\.availableForSale).count) SKU")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.muted)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private func fitBlock(_ fit: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "ruler")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.accent)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.t("product.fit"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.muted)
                Text(fit)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .pawlyCard(padding: 14)
        .padding(.horizontal, 16)
    }

    private var descriptionBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.t("product.description"))
                .font(.system(size: 16, weight: .bold, design: .serif))
                .foregroundStyle(theme.ink)
            Text(product.descriptionText)
                .font(.system(size: 14))
                .foregroundStyle(theme.ink.opacity(0.85))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 2)
    }

    // MARK: - Options

    private var optionsBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(state.t("product.options"))
                .font(.system(size: 16, weight: .bold, design: .serif))
                .foregroundStyle(theme.ink)

            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Text(group.label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.muted)
                        if let selected = selection[group.name],
                           let value = group.values.first(where: { $0.value == selected }) {
                            Text(value.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(theme.ink)
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(group.values) { optionValue in
                                let isSelected = selection[group.name] == optionValue.value
                                let isAvailable = isValueAvailable(group: group.name, value: optionValue.value)
                                Button {
                                    selection[group.name] = optionValue.value
                                    added = false
                                } label: {
                                    Text(optionValue.label)
                                        .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                                        .foregroundStyle(isSelected ? (theme.isDark ? theme.background : .white)
                                                         : (isAvailable ? theme.ink : theme.muted.opacity(0.45)))
                                        .strikethrough(!isAvailable)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(isSelected ? theme.primary : theme.surface, in: Capsule())
                                        .overlay(Capsule().strokeBorder(isSelected ? Color.clear : theme.border, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .disabled(!isAvailable)
                            }
                        }
                    }
                }
            }

            if let variant = selectedVariant, !variant.availableForSale {
                Text(state.t("product.unavailable"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.danger)
            } else if selectedVariant == nil && selection.count == groups.count {
                Text(state.t("product.unavailable"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.danger)
            }
        }
        .padding(.horizontal, 20)
    }

    private func isValueAvailable(group: String, value: String) -> Bool {
        var candidate = selection
        candidate[group] = value
        return product.variants.contains { variant in
            guard variant.availableForSale else { return false }
            for (key, selected) in candidate {
                guard variant.selectedOptions.contains(where: { $0.name == key && $0.value == selected }) else {
                    return false
                }
            }
            return true
        }
    }

    // MARK: - 3D capabilities

    private var capabilitiesBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.t("product.capabilities"))
                .font(.system(size: 16, weight: .bold, design: .serif))
                .foregroundStyle(theme.ink)

            VStack(spacing: 0) {
                capabilityRow(icon: "cube.fill",
                              title: state.t("generate.glb"),
                              value: product.capabilities?.hasGLB == true ? state.t("product.glbReady") : state.t("product.glbNone"),
                              ready: product.capabilities?.hasGLB == true)
                Divider().overlay(theme.border.opacity(0.6))
                capabilityRow(icon: "arkit",
                              title: state.t("generate.usdz"),
                              value: product.capabilities?.hasUSDZ == true ? state.t("generate.ready") : state.t("product.usdzUnavailable"),
                              ready: product.capabilities?.hasUSDZ == true)
                if let skinning = product.capabilities?.hasSkinning {
                    Divider().overlay(theme.border.opacity(0.6))
                    capabilityRow(icon: "figure.walk",
                                  title: state.t("product.skinning"),
                                  value: skinning ? state.t("generate.ready") : state.t("generate.failed"),
                                  ready: skinning)
                }
                if let actions = product.capabilities?.supportedActions, !actions.isEmpty {
                    Divider().overlay(theme.border.opacity(0.6))
                    HStack(spacing: 6) {
                        Image(systemName: "play.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.muted)
                        Text(state.t("product.actions"))
                            .font(.system(size: 13))
                            .foregroundStyle(theme.muted)
                        Spacer()
                        Text(actions.joined(separator: " · "))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(theme.ink)
                    }
                    .padding(.vertical, 11)
                }
            }
            .padding(.horizontal, 14)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1)
            )
        }
        .padding(.horizontal, 20)
    }

    private func capabilityRow(icon: String, title: String, value: String, ready: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(ready ? theme.success : theme.muted)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(theme.ink)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ready ? theme.success : theme.muted)
        }
        .padding(.vertical, 11)
    }

    // MARK: - Bottom bar

    private var addBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                QuantityStepper(quantity: $quantity)
                Button {
                    Task { await addToCart() }
                } label: {
                    HStack(spacing: 8) {
                        if isAdding {
                            ProgressView().tint(theme.isDark ? theme.background : .white)
                        } else {
                            Image(systemName: "bag.badge.plus")
                        }
                        Text(isAdding ? state.t("product.adding") : state.t("product.addToCart"))
                    }
                }
                .buttonStyle(PawlyPrimaryButtonStyle(enabled: canAdd))
                .disabled(!canAdd)
            }
            if added {
                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        state.showCart = true
                    }
                } label: {
                    Text(state.t("cart.title") + " →")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(
            theme.background
                .overlay(alignment: .top) {
                    Rectangle().fill(theme.border.opacity(0.6)).frame(height: 1)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func addToCart() async {
        guard let variant = selectedVariant else { return }
        isAdding = true
        defer { isAdding = false }
        let success = await state.addToCart(product: product,
                                           variant: variant,
                                           petID: state.selectedPet?.petId,
                                           quantity: quantity)
        if success {
            added = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func preselect() {
        if let existing = product.variants.first(where: { variant in
            var matches = true
            for group in groups {
                guard let selected = selection[group.name] else { matches = false; break }
                if !variant.selectedOptions.contains(where: { $0.name == group.name && $0.value == selected }) {
                    matches = false
                    break
                }
            }
            return matches
        }) {
            for option in existing.selectedOptions {
                selection[option.name] = option.value
            }
            return
        }
        let variant = product.variants.first(where: \.availableForSale) ?? product.variants.first
        guard let variant else { return }
        selection = [:]
        for option in variant.selectedOptions {
            selection[option.name] = option.value
        }
    }
}
