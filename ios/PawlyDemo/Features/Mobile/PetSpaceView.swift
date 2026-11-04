import SwiftUI

struct PetSpaceView: View {
    @EnvironmentObject private var store: MobileAppStore
    @Environment(\.pawly) private var theme
    @State private var pets: [PetSummary] = []
    @State private var selectedPet: String?
    @State private var items: [AssetItem] = []
    @State private var cursor: String?
    @State private var busy = false
    @State private var error: String?
    @State private var filter = "all"
    @State private var opened: AssetItem?
    private var petName: String { pets.first { $0.petId == selectedPet }?.name ?? "它" }
    private var visibleItems: [AssetItem] {
        items.filter { filter == "all" || (filter == "model" ? $0.kind == "model" : $0.kind != "model") }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("你和\(petName)的小家").font(.largeTitle.bold())
                        Text("一起长大，每一天。").foregroundStyle(theme.muted)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "sun.max").font(.title).foregroundStyle(theme.primary)
                        .padding(12).background(theme.primarySoft, in: Circle()).accessibilityHidden(true)
                }
                if !pets.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(pets) { pet in
                                Button {
                                    selectedPet = pet.petId
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "pawprint.fill")
                                        Text(pet.name ?? "未命名宠物")
                                    }.font(.body.weight(.semibold)).padding(.horizontal, 18).frame(minHeight: 48)
                                        .foregroundStyle(theme.ink)
                                        .background(selectedPet == pet.petId ? theme.accentSoft : theme.surface,
                                                    in: Capsule())
                                        .overlay(Capsule().stroke(theme.border, lineWidth: 1))
                                }.accessibilityAddTraits(selectedPet == pet.petId ? .isSelected : [])
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Label("默认金毛形象", systemImage: "sparkle").font(.callout.weight(.semibold))
                        Spacer()
                        Text("静态模型").font(.caption).foregroundStyle(theme.muted)
                    }.padding(18)
                    GoldenStage(petID: selectedPet).frame(height: 310)
                    HStack {
                        Image(systemName: "hand.draw")
                        Text("拖动看看它 · 双指缩放").font(.footnote)
                        Spacer()
                    }.foregroundStyle(theme.muted).padding(18)
                }.background(theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 24))
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    
                if pets.isEmpty && !busy {
                    MobileCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("先把网站中的它带过来").font(.headline)
                            Text("在网站完成问卷并验证此邮箱后，宠物资料和已保存作品会出现在这里。")
                                .foregroundStyle(theme.muted)
                        }
                    }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("它的作品集").font(.title2.bold())
                        Text("此邮箱在网站保存的照片、试穿和模型").font(.callout).foregroundStyle(theme.muted)
                    }
                    Spacer()
                    if busy { ProgressView() }
                }
                Picker("作品类型", selection: $filter) {
                    Text("全部").tag("all")
                    Text("图片").tag("image")
                    Text("模型").tag("model")
                }.pickerStyle(.segmented)
                MobileErrorText(text: error)
                if visibleItems.isEmpty && !busy {
                    MobileEmpty(symbol: "photo.on.rectangle.angled", title: "作品会在这里相遇",
                                detail: "网站保存到同一邮箱的作品将同步显示。", retry: { Task { await reload() } })
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 14)], spacing: 14) {
                        ForEach(visibleItems) { asset in
                            Button { opened = asset } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    PrivateAssetThumbnail(asset: asset).frame(height: 160).clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 18))
                                    Text(assetTitle(asset)).font(.body.weight(.semibold)).foregroundStyle(theme.ink)
                                    if let date = asset.createdAt {
                                        Text(date, style: .date).font(.caption).foregroundStyle(theme.muted)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).contentShape(Rectangle()).accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
                                .accessibilityLabel(assetTitle(asset)).accessibilityIdentifier("asset-\(asset.kind == "model" ? "model" : "image")-\(asset.assetId)")
                        }
                    }
                }
                    if cursor != nil {
                        Button("加载更多作品") { Task { await loadMore() } }
                            .buttonStyle(.bordered).frame(maxWidth: .infinity, minHeight: 48).disabled(busy)
                    }
            }.padding(20).frame(maxWidth: 850).frame(maxWidth: .infinity)
        }.background(theme.background).navigationTitle("宠物").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button { Task { await reload() } } label: { Label("同步", systemImage: "arrow.clockwise") }.disabled(busy)
            }
            .refreshable { await reload() }
            .task { await reload() }
            .sheet(item: $opened) { asset in NavigationStack { AssetDetailView(asset: asset) } }
    }

    private func reload() async {
        guard let homes = store.homes, let assets = store.assets else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let result = try await homes.pets()
            pets = result.pets
            if !pets.contains(where: { $0.petId == selectedPet }) { selectedPet = pets.first?.petId }
            let page = try await assets.list(limit: 30)
            items = page.items; cursor = page.nextCursor
        } catch {
            if !store.handleSessionError(error) { self.error = store.friendly(error) }
        }
    }
    private func loadMore() async {
        guard let cursor, let assets = store.assets else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let page = try await assets.list(cursor: cursor, limit: 30)
            let existing = Set(items.map(\.assetId))
            items += page.items.filter { !existing.contains($0.assetId) }
            self.cursor = page.nextCursor
        } catch {
            if !store.handleSessionError(error) { self.error = store.friendly(error) }
        }
    }
}

func assetTitle(_ asset: AssetItem) -> String {
    switch asset.kind {
    case "tryon", "outfit": return "试穿作品"
    case "model": return "宠物模型"
    case "cartoon": return "宠物画像"
    case "photo": return "宠物照片"
    default: return "网站作品"
    }
}

struct PrivateAssetThumbnail: View {
    let asset: AssetItem
    @EnvironmentObject private var store: MobileAppStore
    @Environment(\.pawly) private var theme
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        GeometryReader { geometry in
            ZStack {
            theme.surfaceAlt
            if asset.kind == "model" {
                VStack(spacing: 12) {
                    Image(systemName: "cube.transparent").font(.system(size: 38))
                    Text("3D 模型").font(.callout)
                }.foregroundStyle(theme.ink)
            } else if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped().accessibilityHidden(true)
            } else if failed {
                Label("轻点重试", systemImage: "arrow.clockwise").foregroundStyle(theme.muted)
            } else { ProgressView() }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.accessibilityLabel(assetTitle(asset))
            .task(id: "\(store.sessionID)-\(asset.assetId)") {
                guard asset.kind != "model" else { return }
                do {
                    guard let data = try await store.assets?.data(for: asset), !Task.isCancelled else { return }
                    image = UIImage(data: data); failed = image == nil
                } catch {
                    if !Task.isCancelled { failed = true; store.handleSessionError(error) }
                }
            }
    }
}

struct AssetDetailView: View {
    let asset: AssetItem
    @EnvironmentObject private var store: MobileAppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.pawly) private var theme
    @State private var data: Data?
    @State private var error: String?
    @State private var attempt = 0
    var body: some View {
        VStack(spacing: 20) {
            if let data {
                if asset.kind == "model", asset.format?.lowercased() == "glb" {
                    GLBModelView(data: data).frame(maxHeight: .infinity)
                } else if let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit().padding(12).accessibilityIdentifier("privateAssetImage")
                } else {
                    MobileEmpty(symbol: "doc", title: "暂不支持预览此格式", detail: "作品仍保存在你的账号中。")
                }
            } else if let error {
                MobileEmpty(symbol: "exclamationmark.circle", title: "作品暂时打不开", detail: error) { attempt += 1 }
            } else { ProgressView("正在读取作品").frame(maxHeight: .infinity) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.background)
            .navigationTitle(assetTitle(asset)).navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
            .task(id: attempt) {
                error = nil
                do {
                    if asset.kind == "model" {
                        guard asset.format?.lowercased() == "glb" else {
                            error = "暂不支持预览此模型格式。"; return
                        }
                        data = try await store.modelBytes(asset: asset)
                    } else { data = try await store.assets?.data(for: asset) }
                } catch {
                    if !store.handleSessionError(error) { self.error = store.friendly(error) }
                }
            }
    }
}
