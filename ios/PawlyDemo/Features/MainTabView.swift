import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.pawly) private var theme

    var body: some View {
        TabView(selection: $state.selectedTab) {
            HomeView()
                .tag(PawlyTab.home)
                .tabItem {
                    Label(state.t("tab.home"), systemImage: "house.fill")
                }

            ShopView()
                .tag(PawlyTab.shop)
                .tabItem {
                    Label(state.t("tab.shop"), systemImage: "bag.fill")
                }

            GenerateView()
                .tag(PawlyTab.generate)
                .tabItem {
                    Label(state.t("tab.generate"), systemImage: "sparkles")
                }

            ProfileView()
                .tag(PawlyTab.profile)
                .tabItem {
                    Label(state.t("tab.profile"), systemImage: "person.crop.circle")
                }
        }
        .tint(theme.primary)
        .fontDesign(.rounded)
        .sheet(isPresented: $state.showCart) {
            CartView()
        }
        .task {
            await state.loadPets()
            await state.resolveCartIfPossible()
        }
    }
}

// MARK: - Shared toolbar cart button

struct CartToolbarButton: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.pawly) private var theme

    var body: some View {
        Button {
            state.showCart = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bag.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .frame(width: 38, height: 38)
                    .background(theme.surface, in: Circle())
                    .overlay(Circle().strokeBorder(theme.border, lineWidth: 1))
                if state.cartCount > 0 {
                    Text("\(min(state.cartCount, 99))")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.isDark ? theme.background : .white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(theme.primary, in: Capsule())
                        .offset(x: 4, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.t("a11y.cart"))
    }
}
