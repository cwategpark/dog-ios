import SwiftUI
import PhotosUI
import UIKit

/// Post-login gate: a public nickname and an explicitly chosen avatar are required before
/// social tabs unlock. Existing Pawly controls are reused; no new artwork/assets are added.
struct SocialProfileGateView: View {
    @EnvironmentObject private var store: MobileAppStore
    @Environment(\.pawly) private var theme

    var body: some View {
        Group {
            if store.socialProfileLoading && store.socialProfile == nil {
                VStack(spacing: 18) {
                    ProgressView().tint(theme.primary)
                    Text("正在准备你的公开资料").font(.headline)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.socialProfileError, store.socialProfile == nil {
                MobileEmpty(symbol: "person.crop.circle.badge.exclamationmark",
                            title: "公开资料暂时无法读取", detail: error) {
                    Task { await store.loadSocialProfile() }
                }
            } else {
                SocialProfileCompletionView(editing: false)
            }
        }
        .background(theme.background)
        .task {
            if store.socialProfile == nil { await store.loadSocialProfile() }
        }
    }
}

/// Nickname + avatar editor used both by the login gate and by “我的”.
struct SocialProfileCompletionView: View {
    @EnvironmentObject private var store: MobileAppStore
    @Environment(\.pawly) private var theme
    @Environment(\.dismiss) private var dismiss
    let editing: Bool

    @State private var displayName = ""
    @State private var selectedDefaultKey: String?
    @State private var photoItem: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var photoMime = "image/jpeg"
    @State private var initialised = false
    @State private var busy = false
    @State private var error: String?

    private var keys: [String] {
        let values = store.socialProfile?.defaultAvatarKeys ?? []
        return values.isEmpty ? ["paw", "dog", "cat", "leaf"] : values
    }
    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var hasAvatarChoice: Bool {
        photoData != nil || selectedDefaultKey != nil ||
            (store.socialProfile?.avatar.isUpload == true && store.socialProfile?.avatar.available == true)
    }
    private var canSave: Bool {
        !trimmedName.isEmpty && trimmedName.count <= 40 && hasAvatarChoice && !busy
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image("BrandIcon").resizable().scaledToFit().frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 11))
                    Text(editing ? "编辑公开资料" : "先认识一下你").font(.title2.bold())
                }
                Text(editing
                     ? "这些资料会展示给附近宠友；不会公开你的邮箱或私有宠物照片。"
                     : "登录已成功。填写一个公开昵称并明确选择头像后，即可进入宠物、附近和消息。")
                    .font(.callout).foregroundStyle(theme.muted)

                HStack(spacing: 16) {
                    SocialAvatarView(profile: store.socialProfile,
                                     bytes: photoData ?? store.socialAvatarData,
                                     defaultKey: selectedDefaultKey)
                        .frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("公开头像").font(.headline)
                        Text(photoData == nil ? "选择默认头像，或上传一张照片" : "已选择一张新照片")
                            .font(.caption).foregroundStyle(theme.muted)
                    }
                }

                MobileCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("公开昵称").font(.headline)
                        TextField("例如：小金妈妈", text: $displayName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("socialNameInput")
                        Text("\(trimmedName.count)/40 · 昵称不是真实姓名，可随时修改")
                            .font(.caption).foregroundStyle(theme.muted)
                        MobileErrorText(text: error)
                    }
                }

                MobileCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("选择一个默认头像").font(.headline)
                        Text("默认头像必须由你明确选择；不会自动替你选。")
                            .font(.caption).foregroundStyle(theme.muted)
                        HStack(spacing: 12) {
                            ForEach(keys, id: \.self) { key in
                                Button {
                                    selectedDefaultKey = key
                                    photoData = nil
                                    photoItem = nil
                                } label: {
                                    Image(systemName: SocialProfileService.defaultAvatarSymbol(for: key))
                                        .font(.title2)
                                        .frame(width: 48, height: 48)
                                        .foregroundStyle(selectedDefaultKey == key ? .white : theme.ink)
                                        .background(selectedDefaultKey == key ? MobileStyle.action : theme.accentSoft,
                                                    in: Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("默认头像 \(key)")
                                .accessibilityAddTraits(selectedDefaultKey == key ? .isSelected : [])
                            }
                        }
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Label(photoData == nil ? "上传照片（可稍后补充）" : "重新选择照片",
                                  systemImage: "photo.on.rectangle")
                                .font(.callout.weight(.semibold))
                        }
                        .frame(minHeight: 44)
                        .onChange(of: photoItem) { _, item in
                            Task { await loadPhoto(item) }
                        }
                        Text("上传后会生成受控方形缩略图并移除 EXIF；私有宠物照片不会被直接当作公开头像。")
                            .font(.caption).foregroundStyle(theme.muted)
                    }
                }

                Button {
                    Task { await save() }
                } label: {
                    if busy { ProgressView().tint(.white) } else { Text(editing ? "保存资料" : "保存并进入社交") }
                }
                .buttonStyle(MobileAction())
                .disabled(!canSave)
                .accessibilityIdentifier("saveSocialProfile")

                if editing {
                    Button("取消") { dismiss() }.frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .padding(24).frame(maxWidth: 620).frame(maxWidth: .infinity)
        }
        .background(theme.background)
        .navigationTitle(editing ? "公开资料" : "")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .onAppear { applyProfileIfNeeded() }
        .onChange(of: store.socialProfile) { _, _ in applyProfileIfNeeded() }
    }

    private func applyProfileIfNeeded() {
        guard !initialised, let profile = store.socialProfile else { return }
        initialised = true
        displayName = profile.displayName ?? ""
        selectedDefaultKey = profile.avatar.defaultKey
    }

    @MainActor
    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self), !data.isEmpty else {
                error = "无法读取所选照片"; return
            }
            guard data.count <= 5 * 1024 * 1024 else {
                error = "照片不能超过 5 MB"; return
            }
            let type = item.supportedContentTypes.first { type in
                type.preferredMIMEType == "image/jpeg" || type.preferredMIMEType == "image/png" ||
                    type.preferredMIMEType == "image/webp"
            }
            guard let mime = type?.preferredMIMEType else {
                error = "请选择 JPEG、PNG 或 WebP 图片"; return
            }
            photoData = data
            photoMime = mime
            selectedDefaultKey = nil
            error = nil
        } catch {
            self.error = "无法读取所选照片"
        }
    }

    private func save() async {
        guard canSave else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            if let photoData {
                try await store.saveSocialAvatar(data: photoData, contentType: photoMime,
                                                  displayName: trimmedName)
                self.photoData = nil
            } else {
                try await store.saveSocialProfile(displayName: trimmedName,
                                                   defaultAvatarKey: selectedDefaultKey)
            }
            if editing { dismiss() }
        } catch {
            self.error = store.friendly(error)
        }
    }
}

struct SocialAvatarView: View {
    @Environment(\.pawly) private var theme
    let profile: SocialProfile?
    let bytes: Data?
    let defaultKey: String?

    var body: some View {
        Group {
            if let bytes, let image = UIImage(data: bytes) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: SocialProfileService.defaultAvatarSymbol(
                    for: defaultKey ?? profile?.avatar.defaultKey ?? "paw"))
                    .font(.system(size: 34))
                    .foregroundStyle(theme.ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.accentSoft)
            }
        }
        .clipShape(Circle())
        .overlay(Circle().stroke(theme.border, lineWidth: 1))
        .accessibilityHidden(true)
    }
}
