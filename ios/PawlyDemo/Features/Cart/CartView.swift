import SwiftUI

// MARK: - Cart

struct CartView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.pawly) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var isResolving = false
    @State private var busyLineID: String?
    @State private var isCreatingCheckout = false
    @State private var checkoutRoute: CheckoutRoute?
    @State private var errorMessage: String?

    private var cart: Cart? { state.cart }

    var body: some View {
        NavigationStack {
            Group {
                if isResolving && cart == nil {
                    LoadingStateView(message: state.t("cart.resolving"))
                } else if let cart, cart.lines.isEmpty {
                    ScrollView {
                        EmptyStateView(icon: "bag",
                                       title: state.t("cart.empty"),
                                       hint: state.t("cart.emptyHint"),
                                       actionTitle: state.t("cart.browse")) {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                state.selectedTab = .shop
                            }
                        }
                        .padding(.top, 60)
                        DemoFooter()
                    }
                } else if let cart {
                    cartContent(cart)
                } else {
                    ScrollView {
                        ErrorStateView(message: errorMessage ?? state.t("error.network")) {
                            Task { await loadCart() }
                        }
                        .padding(.top, 50)
                    }
                }
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle(state.t("cart.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(state.t("action.close")) { dismiss() }
                        .foregroundStyle(theme.muted)
                }
            }
            .task {
                await loadCart()
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-runCheckout"),
                   let cart = state.cart, !cart.lines.isEmpty, checkoutRoute == nil {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    await startCheckout(cart)
                }
#endif
            }
            .refreshable { await loadCart() }
            .navigationDestination(item: $checkoutRoute) { route in
                CheckoutView(sessionToken: route.token)
            }
        }
    }

    private func cartContent(_ cart: Cart) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 0) {
                    ForEach(Array(cart.lines.enumerated()), id: \.element.lineId) { index, line in
                        lineRow(line)
                        if index < cart.lines.count - 1 {
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

                if !(cart.warnings ?? []).isEmpty {
                    warningsBlock(cart.warnings ?? [])
                }

                totalsBlock(cart)
                checkoutButton(cart)
                DemoFooter(text: state.t("cart.checkoutNote"))
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
    }

    private func lineRow(_ line: CartLine) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteImage(urlString: line.imageUrl, cornerRadius: 14)
                .frame(width: 64, height: 64)
                .clipped()

            VStack(alignment: .leading, spacing: 5) {
                Text(line.title ?? state.t("cart.line.title"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(2)
                if let variantTitle = line.variantTitle, !variantTitle.isEmpty {
                    Text(variantTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                }
                if let petID = line.petId, let pet = state.pet(withID: petID) {
                    HStack(spacing: 4) {
                        Image(systemName: "pawprint.fill")
                            .font(.system(size: 8))
                        Text(state.t("cart.customization") + " · " + pet.name)
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(theme.accent)
                }
                HStack(spacing: 8) {
                    PriceLabel(money: line.cost)
                    Spacer()
                    lineControls(line)
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 12)
    }

    private func lineControls(_ line: CartLine) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                Button {
                    Task { await decrement(line) }
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .disabled(busyLineID != nil)
                Text("\(line.quantity)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .frame(minWidth: 22)
                Button {
                    Task { await increment(line) }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .disabled(busyLineID != nil)
            }
            .foregroundStyle(theme.ink)
            .background(theme.surfaceAlt, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))

            Button {
                Task { await remove(line) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(busyLineID != nil)
            .accessibilityLabel(state.t("cart.remove"))
        }
        .opacity(busyLineID == line.lineId ? 0.5 : 1)
    }

    private func warningsBlock(_ warnings: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(state.t("cart.warnings"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.muted)
            ForEach(warnings, id: \.self) { warning in
                Text("• \(warning)")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.ink.opacity(0.8))
            }
        }
        .pawlyCard(padding: 14)
    }

    private func totalsBlock(_ cart: Cart) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(state.t("cart.subtotal"))
                    .font(.system(size: 14))
                    .foregroundStyle(theme.muted)
                Spacer()
                PriceLabel(money: cart.linesSubtotal, large: true)
            }

            if let discount = cart.demoDiscountPreview {
                Divider().overlay(theme.border.opacity(0.6))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "tag.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(discount.eligible ? theme.success : theme.muted)
                        Text(state.t("cart.discount"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.ink)
                        Spacer()
                        if let amount = discount.amountOff, discount.eligible {
                            Text("−\(amount.display)")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(theme.success)
                        }
                    }
                    Text(discount.eligible ? state.t("cart.discountEligible") : state.t("cart.discountNotEligible"))
                        .font(.system(size: 11))
                        .foregroundStyle(discount.eligible ? theme.success : theme.muted)
                    if let note = discount.note, !note.isEmpty {
                        Text(note)
                            .font(.system(size: 10))
                            .foregroundStyle(theme.muted)
                    }
                    Text(state.t("cart.discountNote"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.primary)
                }
            }

            Divider().overlay(theme.border.opacity(0.6))
            HStack {
                Text(state.t("cart.total"))
                    .font(.system(size: 16, weight: .bold, design: .serif))
                    .foregroundStyle(theme.ink)
                Spacer()
                PriceLabel(money: cart.estimatedTotal, large: true)
            }
        }
        .pawlyCard(padding: 16)
    }

    private func checkoutButton(_ cart: Cart) -> some View {
        VStack(spacing: 8) {
            Button {
                Task { await startCheckout(cart) }
            } label: {
                HStack(spacing: 8) {
                    if isCreatingCheckout {
                        ProgressView().tint(theme.isDark ? theme.background : .white)
                    } else {
                        Image(systemName: "creditcard.fill")
                    }
                    Text(isCreatingCheckout ? state.t("cart.checkoutCreating") : state.t("cart.checkout"))
                }
            }
            .buttonStyle(PawlyPrimaryButtonStyle())
            .disabled(isCreatingCheckout || cart.lines.isEmpty)
        }
    }

    // MARK: - Actions

    private func loadCart() async {
        guard state.accessToken != nil else { return }
        isResolving = true
        errorMessage = nil
        await state.refreshCart()
        isResolving = false
        if state.cart == nil {
            errorMessage = state.t("error.network")
        }
    }

    private func increment(_ line: CartLine) async {
        guard let cart = state.cart else { return }
        busyLineID = line.lineId
        defer { busyLineID = nil }
        do {
            let updated = try await state.api.addLine(cartID: cart.cartId,
                                                      variantGID: line.variantGid,
                                                      quantity: 1,
                                                      customizationID: line.customizationId,
                                                      petID: line.petId)
            state.cart = updated.value
        } catch {
            state.presentError(error)
            await state.refreshCart()
        }
    }

    private func decrement(_ line: CartLine) async {
        guard let cart = state.cart else { return }
        if line.quantity <= 1 {
            await remove(line)
            return
        }
        busyLineID = line.lineId
        defer { busyLineID = nil }
        do {
            // The demo contract has no quantity PATCH: delete + re-add with the reduced quantity.
            try await state.api.deleteLine(cartID: cart.cartId, lineID: line.lineId)
            let updated = try await state.api.addLine(cartID: cart.cartId,
                                                      variantGID: line.variantGid,
                                                      quantity: line.quantity - 1,
                                                      customizationID: line.customizationId,
                                                      petID: line.petId)
            state.cart = updated.value
        } catch {
            state.presentError(error)
            await state.refreshCart()
        }
    }

    private func remove(_ line: CartLine) async {
        guard let cart = state.cart else { return }
        busyLineID = line.lineId
        defer { busyLineID = nil }
        do {
            try await state.api.deleteLine(cartID: cart.cartId, lineID: line.lineId)
            await state.refreshCart()
        } catch {
            state.presentError(error)
        }
    }

    private func startCheckout(_ cart: Cart) async {
        isCreatingCheckout = true
        defer { isCreatingCheckout = false }
        do {
            let checkout = try await state.api.checkout(cartID: cart.cartId).value
            guard let token = Self.sessionToken(from: checkout.checkoutUrl) else {
                state.presentErrorMessage(state.t("error.generic"))
                return
            }
            checkoutRoute = CheckoutRoute(token: token)
        } catch {
            state.presentError(error)
        }
    }

    static func sessionToken(from urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let session = components.queryItems?.first(where: { $0.name == "session" })?.value,
           !session.isEmpty {
            return session
        }
        let last = url.lastPathComponent
        return last.isEmpty ? nil : last
    }
}

struct CheckoutRoute: Identifiable, Hashable {
    let token: String
    var id: String { token }
}

// MARK: - Checkout (demo)

struct CheckoutView: View {
    let sessionToken: String

    @EnvironmentObject private var state: AppState
    @Environment(\.pawly) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var session: CheckoutSession?
    @State private var order: Order?
    @State private var isLoading = true
    @State private var isConfirming = false
    @State private var errorMessage: String?
    @State private var loadError: String?

    private var cart: Cart? { session?.cart ?? state.cart }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header

                if isLoading {
                    LoadingStateView()
                } else if let order {
                    paidCard(order)
                    if let cart {
                        summaryCard(cart)
                    }
                } else {
                    if let loadError {
                        ErrorStateView(message: loadError) {
                            Task { await loadSession() }
                        }
                    }
                    if let cart {
                        summaryCard(cart)
                    }
                    payBlock
                }

                DemoFooter()
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(theme.background.ignoresSafeArea())
        .navigationTitle(state.t("checkout.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            await loadSession()
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-runCheckout"), order == nil {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await confirmPayment()
            }
#endif
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            if order != nil {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(theme.success)
            } else {
                Image(systemName: "creditcard.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(theme.primary)
            }
            Text(order != nil ? state.t("checkout.paid") : state.t("checkout.unpaid"))
                .font(.system(size: 24, weight: .bold, design: .serif))
                .foregroundStyle(theme.ink)
            Text(order != nil ? state.t("checkout.paidHint") : state.t("checkout.unpaidHint"))
                .font(.system(size: 12))
                .foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private func paidCard(_ order: Order) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            row(state.t("checkout.orderId"), order.orderId)
            row(state.t("checkout.orderStatus"), order.status)
            row(state.t("checkout.total"), order.total.display)
            if let confirmed = order.confirmedAt {
                row(state.t("checkout.paidAt"), Self.formatDate(confirmed))
            }
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                Text(state.t("checkout.paidHint"))
                    .font(.system(size: 11))
            }
            .foregroundStyle(theme.muted)
            .padding(.top, 2)

            Button {
                dismiss()
            } label: {
                Text(state.t("action.done"))
            }
            .buttonStyle(PawlyPrimaryButtonStyle())
            .padding(.top, 4)
        }
        .pawlyCard(padding: 16)
    }

    private func summaryCard(_ cart: Cart) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.t("checkout.summary"))
                .font(.system(size: 16, weight: .bold, design: .serif))
                .foregroundStyle(theme.ink)
            ForEach(cart.lines) { line in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(line.quantity)×")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.muted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.title ?? line.variantGid)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(theme.ink)
                            .lineLimit(2)
                        if let petID = line.petId, let pet = state.pet(withID: petID) {
                            Text(state.t("cart.customization") + " · " + pet.name)
                                .font(.system(size: 10))
                                .foregroundStyle(theme.accent)
                        }
                    }
                    Spacer()
                    Text(line.cost.display)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.ink)
                }
            }
            Divider().overlay(theme.border.opacity(0.6))
            if let preview = cart.demoDiscountPreview, preview.eligible, let amountOff = preview.amountOff {
                HStack {
                    Text(state.t("cart.discount"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.success)
                    Spacer()
                    Text("-" + amountOff.display)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.success)
                }
                Text(state.t("cart.discountNote"))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.muted)
            }
            HStack {
                Text(state.t("checkout.total"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.muted)
                Spacer()
                PriceLabel(money: cart.estimatedTotal, large: true)
            }
            if let status = session?.status {
                HStack {
                    Text(state.t("checkout.sessionStatus"))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.muted)
                    Spacer()
                    PillLabel(text: state.t("checkout.status.\(status)"),
                              tint: status == "confirmed" ? theme.success : theme.primary,
                              background: status == "confirmed" ? theme.accentSoft : theme.primarySoft)
                }
            }
        }
        .pawlyCard(padding: 16)
    }

    private var payBlock: some View {
        VStack(spacing: 10) {
            if let errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                    Text(errorMessage)
                        .font(.system(size: 12))
                }
                .foregroundStyle(theme.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                Task { await confirmPayment() }
            } label: {
                HStack(spacing: 8) {
                    if isConfirming {
                        ProgressView().tint(theme.isDark ? theme.background : .white)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    Text(isConfirming ? state.t("checkout.confirming") : state.t("checkout.payDemo"))
                }
            }
            .buttonStyle(PawlyPrimaryButtonStyle(enabled: !isConfirming))
            .disabled(isConfirming)

            Text(state.t("checkout.unpaidHint"))
                .font(.system(size: 11))
                .foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(theme.muted)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.trailing)
        }
    }

    private func loadSession() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let value = try await state.api.checkoutSession(token: sessionToken).value
            session = value
            if value.status == "confirmed", let orderID = value.orderId {
                order = try? await state.api.order(id: orderID).value
                if order == nil {
                    order = Order(orderId: orderID, status: "paid", total: value.cart?.estimatedTotal ?? Money(amount: "0.00"),
                                  lines: value.cart?.lines.map { OrderLine(title: $0.title, quantity: $0.quantity, cost: $0.cost, variantGid: $0.variantGid) },
                                  createdAt: nil, confirmedAt: nil)
                }
                await state.refreshCart()
            }
        } catch {
            loadError = (error as? APIError)?.displayMessage(language: state.language) ?? error.localizedDescription
        }
    }

    private func confirmPayment() async {
        isConfirming = true
        errorMessage = nil
        defer { isConfirming = false }
        do {
            let paidOrder = try await state.api.confirmCheckout(token: sessionToken).value
            order = paidOrder
            session = CheckoutSession(status: "confirmed", cart: session?.cart, orderId: paidOrder.orderId)
            // Only after confirm() does the UI show paid; refresh the cart from the server.
            await state.refreshCart()
        } catch {
            errorMessage = (error as? APIError)?.displayMessage(language: state.language) ?? state.t("checkout.confirmError")
        }
    }

    static func formatDate(_ iso: String) -> String {
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
