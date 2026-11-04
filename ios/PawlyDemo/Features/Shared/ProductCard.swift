import SwiftUI

struct ProductCard: View {
    let product: Product
    var imageHeight: CGFloat = 148

    @EnvironmentObject private var state: AppState
    @Environment(\.pawly) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                RemoteImage(urlString: product.primaryImageURL, cornerRadius: 18)
                    .frame(maxWidth: .infinity)
                    .frame(height: imageHeight)
                    .clipped()

                if let badge = product.badge?.text(language: state.language), !badge.isEmpty {
                    PillLabel(text: badge)
                        .padding(8)
                }

                Spacer(minLength: 0)
                if product.capabilities?.hasGLB == true {
                    HStack(spacing: 4) {
                        Image(systemName: "cube.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text("3D")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(theme.isDark ? theme.background : .white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(theme.ink.opacity(0.72), in: Capsule())
                    .padding(8)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(product.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(height: 38, alignment: .topLeading)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let price = product.priceRange {
                        PriceLabel(money: price)
                    }
                    if product.hasPriceRange {
                        Text(state.t("product.from"))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.muted)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(10)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                .strokeBorder(theme.border.opacity(theme.isDark ? 0.9 : 0.75), lineWidth: 1)
        )
        .shadow(color: theme.cardShadow, radius: 14, x: 0, y: 7)
    }
}

struct RecommendationCard: View {
    let item: RecommendationItem
    var onTap: () -> Void

    @EnvironmentObject private var state: AppState
    @Environment(\.pawly) private var theme

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .topLeading) {
                    RemoteImage(urlString: item.product.primaryImageURL, cornerRadius: 16)
                        .frame(width: 186, height: 126)
                        .clipped()
                    if let badge = item.product.badge?.text(language: state.language), !badge.isEmpty {
                        PillLabel(text: badge)
                            .padding(7)
                    }
                }

                if let reason = item.localizedReason(language: state.language) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 9, weight: .bold))
                        Text(reason)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .foregroundStyle(theme.accent)
                    .frame(height: 28, alignment: .topLeading)
                }

                Text(item.product.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)

                if let price = item.product.priceRange {
                    PriceLabel(money: price)
                }
            }
            .frame(width: 186, alignment: .leading)
            .padding(10)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(theme.border.opacity(theme.isDark ? 0.9 : 0.75), lineWidth: 1)
            )
            .shadow(color: theme.cardShadow, radius: 12, x: 0, y: 6)
        }
        .buttonStyle(.plain)
    }
}
