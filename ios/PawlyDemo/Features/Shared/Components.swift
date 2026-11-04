import SwiftUI

// MARK: - Theme access

extension View {
    func pawlyCard(padding: CGFloat = 16, radius: CGFloat? = nil) -> some View {
        modifier(PawlyCardModifier(padding: padding, radius: radius))
    }
}

private struct PawlyCardModifier: ViewModifier {
    @Environment(\.pawly) private var theme
    let padding: CGFloat
    let radius: CGFloat?

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: radius ?? theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius ?? theme.cardRadius, style: .continuous)
                    .strokeBorder(theme.border.opacity(theme.isDark ? 0.9 : 0.7), lineWidth: 1)
            )
            .shadow(color: theme.cardShadow, radius: 16, x: 0, y: 8)
    }
}

// MARK: - Buttons

struct PawlyPrimaryButtonStyle: ButtonStyle {
    @Environment(\.pawly) private var theme
    var enabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(theme.isDark ? Color(hex: "#241F1A")! : Color.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(enabled ? theme.primary : theme.muted.opacity(0.4), in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct PawlySecondaryButtonStyle: ButtonStyle {
    @Environment(\.pawly) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(theme.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(theme.surfaceAlt, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct PawlySmallPillStyle: ButtonStyle {
    @Environment(\.pawly) private var theme
    var filled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(filled ? (theme.isDark ? Color(hex: "#171411")! : .white) : theme.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(filled ? theme.primary : theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(filled ? Color.clear : theme.border, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

// MARK: - Pills / chips / badges

struct DemoBadge: View {
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(badgeColor)
                .frame(width: 6, height: 6)
            Text("DEMO")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tintBackground, in: Capsule())
    }

    @Environment(\.pawly) private var theme
    private var badgeColor: Color { theme.primary }
    private var tintBackground: Color { theme.primarySoft }
}

struct PillLabel: View {
    let text: String
    var tint: Color?
    var background: Color?

    @Environment(\.pawly) private var theme

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint ?? theme.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(background ?? theme.primarySoft, in: Capsule())
    }
}

struct SelectableChip: View {
    let title: String
    let isSelected: Bool
    var action: () -> Void

    @Environment(\.pawly) private var theme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? (theme.isDark ? theme.background : .white) : theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? theme.primary : theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(isSelected ? Color.clear : theme.border, lineWidth: 1))
                .animation(.easeOut(duration: 0.15), value: isSelected)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Section header

struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var trailingTitle: String?
    var trailingAction: (() -> Void)?

    @Environment(\.pawly) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 22, weight: .bold, design: .serif))
                    .foregroundStyle(theme.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(theme.muted)
                }
            }
            Spacer()
            if let trailingTitle, let trailingAction {
                Button(trailingTitle, action: trailingAction)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.primary)
            }
        }
    }
}

// MARK: - Remote image

struct RemoteImage: View {
    let urlString: String?
    var contentMode: ContentMode = .fill
    var cornerRadius: CGFloat?
    var baseURL: URL = URL(string: "http://127.0.0.1:8788")!

    @Environment(\.pawly) private var theme

    private var url: URL? {
        guard let urlString, !urlString.isEmpty else { return nil }
        if let url = URL(string: urlString), url.scheme != nil { return url }
        return URL(string: urlString, relativeTo: baseURL)?.absoluteURL
    }

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: contentMode)
                    case .failure:
                        placeholder
                    case .empty:
                        ZStack {
                            placeholder
                            ProgressView().tint(theme.primary)
                        }
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? theme.cardRadius, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [theme.primarySoft, theme.accentSoft],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "pawprint.fill")
                .font(.system(size: 26))
                .foregroundStyle(theme.primary.opacity(0.55))
        }
    }
}

struct PetAvatar: View {
    let urlString: String?
    var size: CGFloat = 64
    var showRing: Bool = true

    @Environment(\.pawly) private var theme

    var body: some View {
        RemoteImage(urlString: urlString, contentMode: .fill, cornerRadius: size / 2)
            .frame(width: size, height: size)
            .overlay(
                Circle().strokeBorder(theme.surface.opacity(showRing ? 0.9 : 0), lineWidth: 3)
            )
            .shadow(color: theme.cardShadow, radius: 8, x: 0, y: 4)
    }
}

// MARK: - States

struct LoadingStateView: View {
    var message: String?
    @Environment(\.pawly) private var theme
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().tint(theme.primary)
            Text(message ?? state.t("common.loading"))
                .font(.footnote)
                .foregroundStyle(theme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

struct ErrorStateView: View {
    let message: String
    var retry: (() -> Void)?

    @Environment(\.pawly) private var theme
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 26))
                .foregroundStyle(theme.muted)
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.muted)
                .padding(.horizontal, 24)
            if let retry {
                Button(state.t("action.retry"), action: retry)
                    .buttonStyle(PawlySmallPillStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    var hint: String?
    var actionTitle: String?
    var action: (() -> Void)?

    @Environment(\.pawly) private var theme

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(theme.primary.opacity(0.7))
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.ink)
            if let hint {
                Text(hint)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(theme.muted)
                    .padding(.horizontal, 20)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(PawlySmallPillStyle(filled: true))
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

// MARK: - Toast

struct ToastOverlay: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.pawly) private var theme

    var body: some View {
        VStack {
            if let toast = state.toast {
                HStack(spacing: 8) {
                    Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(toast.isError ? theme.danger : theme.success)
                    Text(toast.text)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.ink)
                        .lineLimit(3)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))
                .shadow(color: theme.cardShadow, radius: 14, x: 0, y: 6)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.toast)
        .allowsHitTesting(false)
    }
}

// MARK: - Demo footer

struct DemoFooter: View {
    var text: String?
    @Environment(\.pawly) private var theme
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 11))
            Text(text ?? state.t("demo.banner"))
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(theme.muted)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }
}

// MARK: - Price

struct PriceLabel: View {
    let money: Money
    var compareAt: Money?
    var large: Bool = false

    @Environment(\.pawly) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Text(money.display)
                .font(.system(size: large ? 22 : 15, weight: .bold, design: .rounded))
                .foregroundStyle(theme.ink)
            if let compareAt {
                Text(compareAt.display)
                    .font(.system(size: large ? 14 : 12))
                    .foregroundStyle(theme.muted)
                    .strikethrough()
            }
        }
    }
}

// MARK: - Quantity stepper

struct QuantityStepper: View {
    @Binding var quantity: Int
    var minimum: Int = 1
    var maximum: Int = 20

    @Environment(\.pawly) private var theme

    var body: some View {
        HStack(spacing: 0) {
            Button {
                if quantity > minimum { quantity -= 1 }
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .disabled(quantity <= minimum)

            Text("\(quantity)")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .frame(minWidth: 34)

            Button {
                if quantity < maximum { quantity += 1 }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .disabled(quantity >= maximum)
        }
        .foregroundStyle(theme.ink)
        .background(theme.surfaceAlt, in: Capsule())
        .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))
    }
}
