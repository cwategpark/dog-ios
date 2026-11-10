import SwiftUI

struct MobileAccountView: View {
    @EnvironmentObject private var store: MobileAppStore
    @Environment(\.pawly) private var theme
    @State private var error: String?
    @State private var signingOut = false
    @State private var showSignout = false
    @State private var showSocialEditor = false
    @State private var syncing = false
    @State private var synced = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("属于你们的小世界。").font(.largeTitle.bold())
                MobileCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 14) {
                            SocialAvatarView(profile: store.socialProfile,
                                             bytes: store.socialAvatarData,
                                             defaultKey: store.socialProfile?.avatar.defaultKey)
                                .frame(width: 56, height: 56)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(store.socialProfile?.displayName ?? "宠物家长").font(.title3.bold())
                                Text(store.me?.email ?? "").font(.callout).textSelection(.enabled)
                            }
                        }
                        Label("邮箱已验证", systemImage: "checkmark.seal.fill").font(.callout).foregroundStyle(theme.success)
                        Button("编辑公开昵称与头像") { showSocialEditor = true }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("editSocialProfile")
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
                        Text("在宠物页查看此账号的宠物名字、上传照片和模型。商品物流可在下方单独查看。")
                            .foregroundStyle(theme.muted)
                        Button { Task { await sync() } } label: {
                            HStack {
                                if syncing { ProgressView() }
                                Text(syncing ? "正在同步" : "立即同步账号信息")
                            }
                        }.frame(minHeight: 44).disabled(syncing).accessibilityIdentifier("syncWebsiteAccount")
                        if synced { Text("账号已更新，照片和模型将在宠物页重新读取。")
                            .font(.footnote).foregroundStyle(theme.muted).accessibilityIdentifier("websiteSyncComplete") }
                    }
                }
                NavigationLink(value: AccountDestination.logistics) {
                    MobileCard {
                        HStack(spacing: 14) {
                            Image(systemName: "shippingbox").font(.title2).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("商品物流").font(.headline)
                                Text("查看网站订单的发货与配送信息").font(.callout).foregroundStyle(theme.muted)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").accessibilityHidden(true)
                        }.foregroundStyle(theme.ink)
                    }
                }.buttonStyle(.plain).accessibilityIdentifier("websiteLogistics")
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
            .navigationDestination(for: AccountDestination.self) { _ in OrderLogisticsView() }
            .sheet(isPresented: $showSocialEditor) {
                NavigationStack {
                    SocialProfileCompletionView(editing: true)
                        .environmentObject(store)
                }
            }
            .confirmationDialog("退出后，此设备将清除当前账号的登录状态和作品预览。", isPresented: $showSignout) {
                Button("退出登录", role: .destructive) { Task { signingOut = true; await store.logout(); signingOut = false } }.accessibilityIdentifier("confirmLogout")
            }
    }
    private func sync() async {
        syncing = true; synced = false; error = nil
        defer { syncing = false }
        do {
            try await store.finishLogin()
            store.websiteSyncRevision = UUID()
            synced = true
        }
        catch { if !store.handleSessionError(error) { self.error = store.friendly(error) } }
    }
}

private enum AccountDestination: Hashable { case logistics }

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
