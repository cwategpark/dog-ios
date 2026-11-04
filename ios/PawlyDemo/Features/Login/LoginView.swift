import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.pawly) private var theme

    @State private var claimCode = ""
    @State private var showClaimField = false
    @FocusState private var claimFocused: Bool

    private var canClaim: Bool {
        claimCode.count == 6 && claimCode.allSatisfy(\.isNumber) && !state.isAuthBusy
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                    .padding(.top, 34)

                languagePicker
                    .padding(.top, 22)

                VStack(spacing: 12) {
                    demoCustomerButton
                    guestButton
                    claimSection
                }
                .padding(.top, 26)

                if let authError = state.authError {
                    errorBanner(authError)
                        .padding(.top, 14)
                }

                connectionStatus
                    .padding(.top, 16)

                DemoFooter()
                    .padding(.top, 26)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 30)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(background)
        .animation(.easeInOut(duration: 0.2), value: state.authError)
        .animation(.easeInOut(duration: 0.2), value: showClaimField)
        .task { await state.checkHealth() }
    }

    // MARK: - Sections

    private var hero: some View {
        VStack(spacing: 14) {
            Image("BrandIcon")
                .resizable()
                .scaledToFill()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(theme.border.opacity(0.6), lineWidth: 1)
                )
                .shadow(color: theme.cardShadow, radius: 18, x: 0, y: 10)

            HStack(spacing: 8) {
                Text(state.brandName)
                    .font(.system(size: 40, weight: .bold, design: .serif))
                    .foregroundStyle(theme.ink)
                DemoBadge()
                    .padding(.top, 8)
            }

            Text(state.brandTagline)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)

            Text(state.t("login.subtitle"))
                .font(.system(size: 13))
                .foregroundStyle(theme.muted.opacity(0.85))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 2)
        }
    }

    private var languagePicker: some View {
        HStack(spacing: 8) {
            ForEach(L10n.supported, id: \.self) { code in
                Button {
                    state.language = code
                } label: {
                    Text(languageName(code))
                        .font(.system(size: 13, weight: state.language == code ? .bold : .medium))
                        .foregroundStyle(state.language == code ? (theme.isDark ? theme.background : .white) : theme.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(state.language == code ? theme.primary : theme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(state.language == code ? Color.clear : theme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityLabel(state.t("login.langLabel"))
    }

    private var demoCustomerButton: some View {
        Button {
            Task { await state.loginDemoCustomer() }
        } label: {
            HStack(spacing: 10) {
                if state.isAuthBusy {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.isAuthBusy ? state.t("login.connecting") : state.t("login.demoCustomer"))
                    Text(state.t("login.demoCustomerHint"))
                        .font(.system(size: 11, weight: .regular))
                        .opacity(0.85)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
        }
        .buttonStyle(PawlyPrimaryButtonStyle())
        .disabled(state.isAuthBusy)
    }

    private var guestButton: some View {
        Button {
            Task { await state.loginGuest() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.dashed")
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.t("login.guest"))
                    Text(state.t("login.guestHint"))
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(theme.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .foregroundStyle(theme.ink)
        }
        .buttonStyle(PawlySecondaryButtonStyle())
        .disabled(state.isAuthBusy)
    }

    private var claimSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !showClaimField {
                Button {
                    withAnimation { showClaimField = true }
                    claimFocused = true
                } label: {
                    HStack {
                        Image(systemName: "ticket")
                        Text(state.t("login.claimTitle"))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.muted)
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
                            .strokeBorder(theme.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "ticket")
                            .foregroundStyle(theme.primary)
                        Text(state.t("login.claimTitle"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.ink)
                        Spacer()
                    }
                    HStack(spacing: 10) {
                        TextField(state.t("login.claimPlaceholder"), text: $claimCode)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .focused($claimFocused)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .tracking(6)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .background(theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .onChange(of: claimCode) { _, newValue in
                                claimCode = String(newValue.filter(\.isNumber).prefix(6))
                            }
                        Button {
                            Task { await state.claim(code: claimCode) }
                        } label: {
                            if state.isAuthBusy {
                                ProgressView().tint(.white)
                            } else {
                                Text(state.t("login.claimButton"))
                            }
                        }
                        .buttonStyle(PawlySmallPillStyle(filled: true))
                        .disabled(!canClaim)
                    }
                    Text(state.t("login.claimHint"))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                        .strokeBorder(theme.border, lineWidth: 1)
                )
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(theme.danger)
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(theme.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var connectionStatus: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.backendReachable == true ? theme.success : (state.backendReachable == false ? theme.danger : theme.muted))
                .frame(width: 7, height: 7)
            Text(state.backendReachable == true ? state.t("login.connectedHint")
                 : (state.backendReachable == false ? state.t("login.offlineHint") : state.t("common.loading")))
                .font(.system(size: 11))
                .foregroundStyle(theme.muted)
            if state.backendReachable == false {
                Button(state.t("action.retry")) {
                    Task { await state.checkHealth() }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.primary)
            }
        }
    }

    private var background: some View {
        ZStack {
            theme.background.ignoresSafeArea()
            Circle()
                .fill(theme.primarySoft.opacity(theme.isDark ? 0.35 : 0.65))
                .frame(width: 320, height: 320)
                .blur(radius: 60)
                .offset(x: -130, y: -300)
            Circle()
                .fill(theme.accentSoft.opacity(theme.isDark ? 0.3 : 0.7))
                .frame(width: 280, height: 280)
                .blur(radius: 70)
                .offset(x: 150, y: 240)
            theme.background.opacity(0.55)
                .ignoresSafeArea()
        }
        .ignoresSafeArea()
    }

    private func languageName(_ code: String) -> String {
        switch code {
        case "zh-CN": return "中文"
        case "es": return "Español"
        case "en": return "English"
        default: return code
        }
    }
}
