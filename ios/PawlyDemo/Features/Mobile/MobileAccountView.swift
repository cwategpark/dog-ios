import SwiftUI

struct MobileAccountView: View {
    @EnvironmentObject private var store: MobileAppStore
    @Environment(\.pawly) private var theme
    @State private var error: String?
    @State private var signingOut = false
    @State private var showSignout = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("属于你们的小世界。").font(.largeTitle.bold())
                MobileCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 14) {
                            Image(systemName: "person.crop.circle.fill").font(.system(size: 48)).foregroundStyle(theme.accent)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(store.me?.fullName ?? "宠物家长").font(.title3.bold())
                                Text(store.me?.email ?? "").font(.callout).textSelection(.enabled)
                            }
                        }
                        Label("邮箱已验证", systemImage: "checkmark.seal.fill").font(.callout).foregroundStyle(theme.success)
                        Divider()
                        Text("专属用户识别码").font(.headline)
                        Text(store.me?.userId ?? "").font(.footnote.monospaced()).textSelection(.enabled)
                            .accessibilityIdentifier("userIdentifier")
                        Text("网站与 iOS 通过同一邮箱关联此身份。").font(.footnote).foregroundStyle(theme.muted)
                    }
                }
                MobileCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("网站作品同步", systemImage: "arrow.triangle.2.circlepath").font(.headline)
                        Text("网站上验证此邮箱并保存的图片、试穿作品和模型，可在宠物页的作品集中查看。")
                            .foregroundStyle(theme.muted)
                        Button("立即同步账号信息") { Task { await sync() } }.frame(minHeight: 44)
                    }
                }
                NavigationLink { MobileBlocksView() } label: {
                    MobileCard {
                        HStack {
                            Label("屏蔽的用户", systemImage: "hand.raised")
                            Spacer()
                            Image(systemName: "chevron.right")
                        }.foregroundStyle(theme.ink)
                    }
                }.buttonStyle(.plain)
                MobileErrorText(text: error)
                Button("退出登录", role: .destructive) { showSignout = true }
                    .frame(maxWidth: .infinity, minHeight: 48).buttonStyle(.bordered)
                    .disabled(signingOut).accessibilityIdentifier("logout")
                Text("外观跟随系统 · 位置仅在主动开启发现时使用")
                    .font(.footnote).foregroundStyle(theme.muted).frame(maxWidth: .infinity)
            }.padding(20).frame(maxWidth: 700).frame(maxWidth: .infinity)
        }.background(theme.background).navigationTitle("我的").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("退出后，此设备将清除当前账号的登录状态和作品预览。", isPresented: $showSignout) {
                Button("退出登录", role: .destructive) { Task { signingOut = true; await store.logout(); signingOut = false } }.accessibilityIdentifier("confirmLogout")
            }
    }
    private func sync() async {
        do { try await store.finishLogin() }
        catch { if !store.handleSessionError(error) { self.error = store.friendly(error) } }
    }
}

struct MobileBlocksView: View {
    @EnvironmentObject private var store: MobileAppStore
    @State private var items: [BlockItem] = []
    @State private var error: String?
    var body: some View {
        List {
            if items.isEmpty { Text("暂未屏蔽任何用户").foregroundStyle(.secondary) }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                if let ref = item.resolvedPublicRef {
                    HStack {
                        Text("宠友 · \(String(ref.suffix(8)))")
                        Spacer()
                        Button("解除屏蔽") { Task { await unblock(ref) } }.frame(minHeight: 44)
                    }
                }
            }
            MobileErrorText(text: error)
        }.navigationTitle("屏蔽的用户").task { await load() }.refreshable { await load() }
    }
    private func load() async {
        do { items = try await store.contacts?.blocks().items ?? [] }
        catch { if !store.handleSessionError(error) { self.error = store.friendly(error) } }
    }
    private func unblock(_ ref: String) async {
        do { try await store.contacts?.unblock(publicRef: ref); await load() }
        catch { if !store.handleSessionError(error) { self.error = store.friendly(error) } }
    }
}
