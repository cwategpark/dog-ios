import SwiftUI
import MapKit

struct NearbyPetsView: View {
    @EnvironmentObject private var store: MobileAppStore
    @Environment(\.pawly) private var theme
    @State private var items: [NearbyItem] = []
    @State private var enabled = false
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var chooseRegion = false
    @State private var radius = 10
    @State private var position: MapCameraPosition = .automatic
    @State private var requested = Set<String>()
    @State private var locationProvider = CoreLocationProvider()
    @State private var selected: NearbyItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("好朋友，也许就在附近。").font(.largeTitle.bold())
                    Text("让下一次散步，多一个伙伴。").foregroundStyle(theme.muted)
                }
                Map(position: $position) {
                    ForEach(items) { item in
                        if let coordinate = coarseCoordinate(item.coarseRegion?.grid) {
                            MapCircle(center: coordinate, radius: 2800)
                                .foregroundStyle(theme.accent.opacity(0.16))
                                .stroke(theme.accent.opacity(0.5), lineWidth: 1)
                            Annotation(item.pet?.name ?? "宠友所在区域", coordinate: coordinate) {
                                Button { selected = item } label: {
                                    Image(systemName: "pawprint.fill").font(.title3)
                                        .foregroundStyle(theme.ink).frame(width: 48, height: 48)
                                        .background(theme.accentSoft, in: Circle())
                                        .overlay(Circle().stroke(theme.surface, lineWidth: 3))
                                }.accessibilityLabel("查看\(item.pet?.name ?? "附近宠友")的粗略区域")
                            }
                        }
                    }
                }.mapControls { MapCompass(); MapScaleView() }
                    .frame(height: 290).clipShape(RoundedRectangle(cornerRadius: 24))
                    .accessibilityIdentifier("nearbyMap")
                Text("地图圆圈代表粗略区域，约 5 公里网格；不代表宠友的实时位置。")
                    .font(.footnote).foregroundStyle(theme.muted)
                if !enabled {
                    MobileCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("准备好认识新朋友了吗？", systemImage: "location.circle").font(.headline)
                            Text("开启发现后，附近宠友能看到宠物公开资料及粗略区域。你可以随时关闭。")
                                .foregroundStyle(theme.muted)
                            Button { Task { await useLocation() } } label: { Text(busy ? "正在获取区域…" : "使用当前位置，开启发现") }
                                .buttonStyle(MobileAction()).disabled(busy)
                                .accessibilityIdentifier("enableLocation")
                            Button("在地图上选择区域") { chooseRegion = true }.frame(minHeight: 44)
                                .accessibilityIdentifier("chooseRegion")
                        }
                    }
                } else {
                    HStack {
                        Label("发现已开启", systemImage: "checkmark.circle.fill").foregroundStyle(theme.success)
                        Spacer()
                        Button("关闭") { Task { await disable() } }.frame(minHeight: 44).disabled(busy)
                    }
                    Picker("搜索范围", selection: $radius) {
                        Text("5 公里").tag(5); Text("10 公里").tag(10); Text("25 公里").tag(25)
                    }.pickerStyle(.segmented)
                        .onChange(of: radius) { _, _ in Task { await refresh() } }
                    HStack {
                        Text("附近的宠友").font(.title2.bold())
                        Spacer()
                        if busy { ProgressView() }
                    }
                    if items.isEmpty && !busy {
                        MobileEmpty(symbol: "leaf", title: "还没有发现宠友", detail: "稍后再来看看，或扩大搜索范围。")
                    }
                    ForEach(items) { item in
                        MobileCard { nearbyCard(item) }
                    }
                }
                MobileErrorText(text: error)
                if let notice { Text(notice).font(.callout).foregroundStyle(theme.success) }
            }.padding(20).frame(maxWidth: 850).frame(maxWidth: .infinity)
        }.background(theme.background).navigationTitle("附近").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button { Task { await refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }.disabled(busy) }
            .refreshable { await refresh() }.task { await refresh() }
            .sheet(isPresented: $chooseRegion) {
                RegionChooser { coordinate in
                    chooseRegion = false
                    Task { await enable(coordinate) }
                }
            }
            .sheet(item: $selected) { item in
                NavigationStack {
                    VStack { MobileCard { nearbyCard(item) }; Spacer() }.padding(20).background(theme.background)
                        .navigationTitle("认识宠友").navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("完成") { selected = nil } }
                }.presentationDetents([.medium, .large])
            }
    }

    @ViewBuilder private func nearbyCard(_ item: NearbyItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            PetInitial(name: item.pet?.name ?? "宠友")
            VStack(alignment: .leading, spacing: 7) {
                Text(item.pet?.name ?? "附近宠友").font(.headline)
                Text([item.pet?.breed, distanceLabel(item.distanceBucket)].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(theme.muted)
                Text("先发送联系申请，对方接受后即可聊天。").font(.footnote).foregroundStyle(theme.muted)
                Button(requested.contains(item.publicRef) ? "申请已发送" : "认识一下") {
                    Task { await request(item) }
                }.buttonStyle(.bordered).frame(minHeight: 44).disabled(requested.contains(item.publicRef) || busy)
            }
            Spacer(minLength: 0)
        }
    }
    private func useLocation() async {
        busy = true; error = nil
        do { let fix = try await locationProvider.currentFix(timeout: 15); await enable(fix.coordinate) }
        catch { self.error = error.localizedDescription; busy = false }
    }
    private func enable(_ coordinate: GeoCoordinate) async {
        guard let service = store.discoveryService else { return }
        busy = true; error = nil
        do {
            let status = try await service.setDiscovery(enabled: true, coordinate: coordinate, radiusKm: radius)
            store.discovery = status; enabled = status.enabled
            if let center = coarseCoordinate(status.grid) {
                position = .region(MKCoordinateRegion(center: center, latitudinalMeters: 26000, longitudinalMeters: 26000))
            }
            await refresh()
        } catch {
            busy = false
            if !store.handleSessionError(error) { self.error = store.friendly(error) }
        }
    }
    private func disable() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            store.discovery = try await store.discoveryService?.disableDiscovery()
            enabled = false; items = []; requested = []
        } catch { if !store.handleSessionError(error) { self.error = store.friendly(error) } }
    }
    private func refresh() async {
        guard let service = store.discoveryService else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            items = try await service.nearby(radiusKm: radius).items; enabled = true
        } catch {
            if let api = error as? MobileAPIError, api.isForbidden {
                enabled = false; items = []
            } else if !store.handleSessionError(error) { self.error = store.friendly(error) }
        }
    }
    private func request(_ item: NearbyItem) async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let result = try await store.contacts?.requestContact(targetPublicRef: item.publicRef)
            requested.insert(item.publicRef)
            notice = (result?.isAutoAccepted == true || result?.contactId != nil || result?.status == "accepted") ? "你们已经成为联系人，去消息中打个招呼吧。" : "申请已发送，接受后即可聊天。"
        } catch { if !store.handleSessionError(error) { self.error = store.friendly(error) } }
    }
}

func coarseCoordinate(_ grid: String?) -> CLLocationCoordinate2D? {
    guard let grid else { return nil }
    let values = grid.split(separator: ":").compactMap { Double($0) }
    guard values.count == 2 else { return nil }
    let lat = (values[0] + 0.5) * 0.05, lon = (values[1] + 0.5) * 0.05
    guard abs(lat) <= 90, abs(lon) <= 180 else { return nil }
    return CLLocationCoordinate2D(latitude: lat, longitude: lon)
}

func distanceLabel(_ bucket: String?) -> String {
    switch bucket {
    case "lt_1km": return "约 1 公里内"
    case "1_3km": return "约 1–3 公里"
    case "3_10km": return "约 3–10 公里"
    case "10_25km": return "约 10–25 公里"
    default: return "同一区域附近"
    }
}

private struct RegionChooser: View {
    let choose: (GeoCoordinate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var center = CLLocationCoordinate2D(latitude: 31.23, longitude: 121.47)
    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 31.23, longitude: 121.47),
                           latitudinalMeters: 100000, longitudinalMeters: 100000))
    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text("移动地图，选择希望认识宠友的区域。").padding(.horizontal)
                ZStack {
                    Map(position: $position).onMapCameraChange(frequency: .onEnd) { center = $0.region.center }
                    Image(systemName: "plus.circle.fill").font(.largeTitle).foregroundStyle(MobileStyle.action)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }.accessibilityLabel("选择区域地图")
                Button("使用此区域，开启发现") { choose(GeoCoordinate(lat: center.latitude, lon: center.longitude)) }
                    .buttonStyle(MobileAction()).padding(20).accessibilityIdentifier("confirmRegion")
            }.navigationTitle("选择区域").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("取消") { dismiss() } }
        }
    }
}
