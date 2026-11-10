import SwiftUI

struct MobileRootView: View {
    @EnvironmentObject private var store: MobileAppStore
    @Environment(\.colorScheme) private var colorScheme
    private var theme: PawlyTheme { colorScheme == .dark ? .fallbackDark : .fallbackLight }

    var body: some View {
        Group {
            if store.starting {
                VStack(spacing: 20) {
                    Image(systemName: "pawprint.fill").font(.system(size: 48)).foregroundStyle(theme.primary)
                    Text("Pawly").font(.largeTitle.bold())
                    ProgressView("正在打开你和它的小家")
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.background)
            } else if let error = store.startupError {
                MobileEmpty(symbol: "wifi.exclamationmark", title: "暂时无法连接", detail: error) {
                    Task { await store.bootstrap() }
                }
                .overlay(alignment: .bottom) {
                    if store.client?.hasSession == true {
                        Button("退出此账号") { Task { await store.logout() } }.padding(32)
                    }
                }
            } else if store.me != nil {
                if store.needsSocialProfile {
                    SocialProfileGateView()
                } else {
                    MobileTabs().id(store.sessionID)
                }
            } else {
                MobileLoginView()
            }
        }
        .environment(\.pawly, theme)
        .foregroundStyle(theme.ink)
        .tint(MobileStyle.action)
        .task { await store.bootstrap() }
    }
}

struct MobileTabs: View {
    var body: some View {
        TabView {
            NavigationStack { PetSpaceView() }
                .tabItem { Label("宠物", systemImage: "pawprint.fill") }.accessibilityIdentifier("petTab")
            NavigationStack { NearbyPetsView() }
                .tabItem { Label("附近", systemImage: "map.fill") }.accessibilityIdentifier("nearbyTab")
            NavigationStack { PetContactsView() }
                .tabItem { Label("消息", systemImage: "bubble.left.and.bubble.right.fill") }.accessibilityIdentifier("messagesTab")
            NavigationStack { MobileAccountView() }
                .tabItem { Label("我的", systemImage: "person.crop.circle") }.accessibilityIdentifier("accountTab")
        }
    }
}

enum MobileStyle {
    static let action = Color.hex("#B9431F")
}

struct MobileCard<Content: View>: View {
    @Environment(\.pawly) private var theme
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(theme.border, lineWidth: 1))
    }
}

struct MobileAction: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(.white).background(MobileStyle.action.opacity(!enabled ? 0.45 : (configuration.isPressed ? 0.75 : 1)),
            in: RoundedRectangle(cornerRadius: 16))
    }
}

struct MobileEmpty: View {
    let symbol: String
    let title: String
    let detail: String
    var retry: (() -> Void)? = nil
    @Environment(\.pawly) private var theme
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 32)).foregroundStyle(theme.muted).accessibilityHidden(true)
            Text(title).font(.title3.bold())
            Text(detail).font(.body).foregroundStyle(theme.muted).multilineTextAlignment(.center)
            if let retry { Button("重试", action: retry).buttonStyle(.bordered).frame(minHeight: 44) }
        }.padding(28).frame(maxWidth: .infinity)
    }
}

struct MobileErrorText: View {
    let text: String?
    var body: some View {
        if let text {
            Label(text, systemImage: "exclamationmark.circle")
                .font(.callout).foregroundStyle(Color.hex("#B43629"))
                .accessibilityAddTraits(.updatesFrequently)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PetInitial: View {
    var name: String
    @Environment(\.pawly) private var theme
    var body: some View {
        Image(systemName: "pawprint.fill").font(.title3)
            .foregroundStyle(theme.ink).frame(width: 48, height: 48)
            .background(theme.accentSoft, in: Circle())
            .accessibilityLabel(name)
    }
}

struct MobileLoginView: View {
    @EnvironmentObject private var store: MobileAppStore
    @Environment(\.pawly) private var theme
    @State private var email = ""
    @State private var code = ""
    @State private var challenge: EmailChallenge?
    @State private var busy = false
    @State private var error: String?
    @State private var resendAt = Date.distantPast
    @FocusState private var focus: Field?
    private enum Field { case email, code }
    private var validEmail: Bool {
        let value = IdentityService.normalizedEmail(email)
        return value.contains("@") && value.split(separator: "@").last?.contains(".") == true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) {
                    Image("BrandIcon").resizable().scaledToFit().frame(width: 42, height: 42).clipShape(RoundedRectangle(cornerRadius: 12))
                    Text("Pawly").font(.title2.bold())
                }.padding(.top, 32)
                VStack(alignment: .leading, spacing: 12) {
                    Text("把它的小世界，\n带在身边。").font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
                    Text("用网站为宠物填写的同一邮箱登录，查看它的资料、照片与专属模型。")
                        .foregroundStyle(theme.muted)
                }
                MobileCard {
                    VStack(alignment: .leading, spacing: 16) {
                        if challenge == nil {
                            Text("你的邮箱").font(.headline)
                            TextField("name@example.com", text: $email)
                                .textContentType(.emailAddress).keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .focused($focus, equals: .email).textFieldStyle(.roundedBorder)
                                .frame(minHeight: 44).accessibilityIdentifier("emailInput")
                            Button { Task { await start() } } label: {
                                if busy { ProgressView().tint(.white) } else { Text("获取验证码") }
                            }.buttonStyle(MobileAction()).disabled(!validEmail || busy).accessibilityIdentifier("sendCode")
                        } else {
                            Text("查看你的邮箱").font(.title3.bold())
                            Text("请输入发往 \(challenge?.emailMasked ?? email) 的验证码。").foregroundStyle(theme.muted)
                            TextField("6 位验证码", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                                .textFieldStyle(.roundedBorder).focused($focus, equals: .code)
                                .frame(minHeight: 44).accessibilityIdentifier("otpInput")
                                .onChange(of: code) { _, value in code = String(value.filter(\.isNumber).prefix(6)) }
                            Button { Task { await verify() } } label: {
                                if busy { ProgressView().tint(.white) } else { Text("验证并登录") }
                            }.buttonStyle(MobileAction()).disabled(code.count != 6 || busy).accessibilityIdentifier("verifyLogin")
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let remaining = max(0, Int(ceil(resendAt.timeIntervalSince(context.date))))
                                Button(remaining > 0 ? "\(remaining) 秒后可重发" : "重新发送验证码") {
                                    Task { await start() }
                                }.disabled(remaining > 0 || busy).frame(minHeight: 44)
                            }
                            Button("使用其他邮箱") { challenge = nil; code = ""; error = nil; focus = .email }
                                .disabled(busy).frame(minHeight: 44)
                            #if DEBUG
                            if challenge?.delivery == "outbox", let devCode = challenge?.devCode {
                                Text("开发联调验证码：\(devCode)").font(.caption.monospaced())
                                    .foregroundStyle(theme.muted).accessibilityIdentifier("devOTP")
                            }
                            #endif
                        }
                        MobileErrorText(text: error)
                    }
                }
                Label("同一邮箱，一个专属身份。", systemImage: "checkmark.shield")
                    .font(.callout).foregroundStyle(theme.muted)
                Text("网站作品需先在网站验证邮箱并保存到此账号，之后即可在这里同步。")
                    .font(.footnote).foregroundStyle(theme.muted)
            }.padding(24).frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
        }.background(theme.background).scrollDismissesKeyboard(.interactively)
    }

    private func start() async {
        guard let identity = store.identity else { error = store.configurationError; return }
        busy = true; error = nil
        defer { busy = false }
        do {
            challenge = try await identity.startEmailVerification(email: email)
            resendAt = Date().addingTimeInterval(TimeInterval(challenge?.cooldownSeconds ?? 60))
            code = ""
            focus = .code
            #if DEBUG
            if challenge?.delivery == "outbox" { code = challenge?.devCode ?? "" }
            #endif
        } catch { self.error = store.friendly(error) }
    }
    private func verify() async {
        guard let identity = store.identity, let challenge else { return }
        busy = true; error = nil; focus = nil
        defer { busy = false }
        do {
            _ = try await identity.verifyEmail(challengeId: challenge.challengeId, code: code)
            // OTP has already been consumed and credentials are stored. Profile
            // failures now use the root retry route, which only retries /me.
            await store.bootstrap()
        } catch { self.error = store.friendly(error) }
    }
}
