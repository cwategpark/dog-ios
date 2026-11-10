import SwiftUI

struct OrderLogisticsView: View {
    @EnvironmentObject private var store: MobileAppStore
    @Environment(\.pawly) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var orders: [LogisticsOrder] = []
    @State private var cursor: String?
    @State private var busy = false
    @State private var loaded = false
    @State private var error: String?
    @State private var lastSynced: Date?
    @State private var loadID = UUID()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("包裹到哪里了").font(.largeTitle.bold())
                    Text("查看此账号在网站购买商品的发货与配送信息。")
                        .foregroundStyle(theme.muted)
                    if let lastSynced {
                        Text("上次同步：\(lastSynced.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote).foregroundStyle(theme.muted)
                    }
                }
                if busy && !loaded {
                    ProgressView("正在同步物流").frame(maxWidth: .infinity, minHeight: 120)
                }
                if let error {
                    MobileCard {
                        MobileEmpty(symbol: "shippingbox", title: "物流暂时无法同步", detail: error) {
                            Task { await load() }
                        }
                    }.accessibilityIdentifier("logisticsUnavailable")
                }
                if loaded && orders.isEmpty && error == nil && cursor == nil {
                    MobileEmpty(symbol: "shippingbox", title: "暂无商品物流",
                                detail: "此账号当前没有可显示的订单。网站新订单的配送信息会在这里同步。")
                        .accessibilityIdentifier("logisticsEmpty")
                }
                ForEach(orders) { order in orderCard(order) }
                if cursor != nil {
                    Button { Task { await load(more: true) } } label: {
                        HStack {
                            if busy { ProgressView() }
                            Text("加载更多物流")
                        }.frame(maxWidth: .infinity, minHeight: 48)
                    }.buttonStyle(.bordered).disabled(busy).accessibilityIdentifier("moreLogistics")
                }
            }.padding(20).frame(maxWidth: 700).frame(maxWidth: .infinity)
        }.background(theme.background).navigationTitle("商品物流").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button { Task { await load() } } label: { Label("同步物流", systemImage: "arrow.clockwise") }
                    .disabled(busy).accessibilityIdentifier("refreshLogistics")
            }
            .task(id: store.websiteSyncRevision) { await load() }
            .refreshable { await load() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await load() } }
            }
    }

    private func orderCard(_ order: LogisticsOrder) -> some View {
        MobileCard {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("订单 \(order.name)").font(.title3.bold())
                    Label(statusText(order.status), systemImage: "shippingbox")
                        .font(.body.weight(.semibold))
                    if let date = parsedDate(order.processedAt) {
                        Text(date, style: .date).font(.footnote).foregroundStyle(theme.muted)
                    }
                }
                ForEach(Array(order.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 16) {
                        Text(item.title).frame(maxWidth: .infinity, alignment: .leading)
                        Text("× \(item.quantity)").foregroundStyle(theme.muted)
                    }.accessibilityElement(children: .combine)
                }
                if order.shipments.isEmpty {
                    Text("暂无运单信息，发货后会在这里更新。")
                        .font(.callout).foregroundStyle(theme.muted)
                }
                ForEach(Array(order.shipments.enumerated()), id: \.offset) { index, shipment in
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text(order.shipments.count > 1 ? "包裹 \(index + 1) · \(statusText(shipment.status))" : statusText(shipment.status))
                            .font(.headline)
                        if let raw = shipment.updatedAt, let date = parsedDate(raw) {
                            Text("更新于 \(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.footnote).foregroundStyle(theme.muted)
                        }
                        if shipment.tracking.isEmpty {
                            Text("承运商暂未提供运单信息。")
                                .font(.callout).foregroundStyle(theme.muted)
                        }
                        ForEach(Array(shipment.tracking.enumerated()), id: \.offset) { _, tracking in
                            VStack(alignment: .leading, spacing: 8) {
                                if let company = tracking.company, !company.isEmpty {
                                    Text(company).font(.body.weight(.semibold))
                                }
                                if let number = tracking.number, !number.isEmpty {
                                    Text("运单号：\(number)").textSelection(.enabled)
                                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                                }
                                if let url = tracking.url {
                                    Link(destination: url) { Label("查看承运商物流", systemImage: "arrow.up.right.square") }
                                        .frame(minHeight: 44).accessibilityIdentifier("carrierTrackingLink")
                                }
                            }
                        }
                    }
                }
            }
        }.accessibilityIdentifier("logisticsOrder")
    }

    private func load(more: Bool = false) async {
        guard (!more || !busy), let client = store.client else { return }
        let operation = UUID()
        loadID = operation
        let generation = client.sessionGeneration
        let pageCursor = more ? cursor : nil
        busy = true; error = nil
        defer { if loadID == operation { busy = false } }
        do {
            let page = try await LogisticsService(client: client).orders(cursor: pageCursor)
            guard loadID == operation, client.sessionGeneration == generation, !Task.isCancelled else { return }
            if let next = page.nextCursor, next == pageCursor {
                throw MobileAPIError.invalidResponse("物流分页暂不可用，请重新同步。")
            }
            var seen = Set(more ? orders.map(\.id) : [])
            let incoming = page.items.filter { seen.insert($0.id).inserted }
            orders = more ? orders + incoming : incoming
            cursor = page.nextCursor
            loaded = true; lastSynced = Date()
        } catch {
            guard loadID == operation, client.sessionGeneration == generation, !Task.isCancelled else { return }
            if !store.handleSessionError(error) {
                if let api = error as? MobileAPIError,
                   ["logistics_not_configured", "logistics_temporarily_unavailable"].contains(api.code ?? "") {
                    self.error = "订单物流服务暂不可用，请稍后重试。"
                } else { self.error = store.friendly(error) }
            }
        }
    }

    private func parsedDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func statusText(_ value: String) -> String {
        switch value.uppercased() {
        case "UNFULFILLED", "OPEN": return "待发货"
        case "PARTIALLY_FULFILLED": return "部分商品已发货"
        case "FULFILLED", "SUCCESS", "CONFIRMED": return "已发货"
        case "IN_PROGRESS", "PENDING", "SCHEDULED": return "正在准备发货"
        case "IN_TRANSIT": return "运输中"
        case "OUT_FOR_DELIVERY": return "派送中"
        case "DELIVERED": return "已送达"
        case "ATTEMPTED_DELIVERY": return "曾尝试派送"
        case "READY_FOR_PICKUP": return "待取件"
        case "FAILURE": return "配送出现异常"
        case "CANCELLED", "CANCELED", "RESTOCKED": return "发货已取消"
        case "ON_HOLD": return "发货暂缓"
        default: return "物流状态更新中"
        }
    }
}
