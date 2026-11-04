import SwiftUI

struct PetContactsView: View {
    @EnvironmentObject private var store: MobileAppStore
    @Environment(\.pawly) private var theme
    @State private var contacts: [ContactItem] = []
    @State private var incoming: [ContactRequestItem] = []
    @State private var outgoing: [ContactRequestItem] = []
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("从一声你好开始。").font(.largeTitle.bold())
                Text("认识彼此，也让它们认识彼此。").foregroundStyle(theme.muted)
                MobileErrorText(text: error)
                if !incoming.isEmpty {
                    Text("新的联系申请").font(.title2.bold())
                    ForEach(incoming) { request in
                        MobileCard {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack { PetInitial(name: request.pet?.name ?? "宠友")
                                    Text(request.pet?.name ?? "新的宠友").font(.headline) }
                                HStack(spacing: 18) {
                                    Button("接受") { Task { await act(request, accept: true) } }
                                        .buttonStyle(.borderedProminent).disabled(busy)
                                    Button("暂不接受") { Task { await act(request, accept: false) } }
                                        .buttonStyle(.bordered).disabled(busy)
                                }.frame(minHeight: 44)
                            }
                        }
                    }
                }
                HStack {
                    Text("我的宠友").font(.title2.bold())
                    Spacer()
                    if busy { ProgressView() }
                }
                if contacts.isEmpty && !busy {
                    MobileEmpty(symbol: "bubble.left.and.bubble.right", title: "等待第一声你好",
                                detail: "在附近认识宠友，对方接受联系申请后，你们就可以聊天。")
                }
                ForEach(contacts) { contact in
                    NavigationLink {
                        PetChatView(contact: contact)
                    } label: {
                        MobileCard {
                            HStack(spacing: 14) {
                                PetInitial(name: contact.pet?.name ?? "宠友")
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(contact.pet?.name ?? "宠友").font(.headline)
                                    Text("聊聊它们的日常").font(.callout).foregroundStyle(theme.muted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(theme.muted)
                            }.foregroundStyle(theme.ink)
                        }
                    }.buttonStyle(.plain).accessibilityIdentifier("contact-\(contact.contactId)")
                }
                if !outgoing.isEmpty {
                    Text("已发送的申请").font(.headline)
                    ForEach(outgoing) { request in
                        HStack {
                            Text(request.pet?.name ?? "宠友")
                            Spacer()
                            Text("等待接受").foregroundStyle(theme.muted)
                        }.font(.callout).padding(.vertical, 10)
                    }
                }
            }.padding(20).frame(maxWidth: 850).frame(maxWidth: .infinity)
        }.background(theme.background).navigationTitle("消息").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button { Task { await load() } } label: { Label("刷新", systemImage: "arrow.clockwise") }.disabled(busy) }
            .task { await load() }.refreshable { await load() }
    }
    private func load() async {
        guard let service = store.contacts else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            contacts = try await service.contacts().items
            incoming = try await service.requests(direction: .incoming).items.filter { $0.status == "pending" }
            outgoing = try await service.requests(direction: .outgoing).items.filter { $0.status == "pending" }
        } catch { if !store.handleSessionError(error) { self.error = store.friendly(error) } }
    }
    private func act(_ request: ContactRequestItem, accept: Bool) async {
        busy = true; error = nil
        do {
            if accept { _ = try await store.contacts?.accept(requestId: request.requestId) }
            else { _ = try await store.contacts?.decline(requestId: request.requestId) }
            await load()
        } catch { busy = false; if !store.handleSessionError(error) { self.error = store.friendly(error) } }
    }
}

struct PetChatView: View {
    let contact: ContactItem
    @EnvironmentObject private var store: MobileAppStore
    @Environment(\.pawly) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [ChatMessage] = []
    @State private var before: Double?
    @State private var beforeID: String?
    @State private var draft = ""
    @State private var pending: (id: String, body: String)?
    @State private var error: String?
    @State private var loading = false
    @State private var sending = false
    @State private var confirmingBlock = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if before != nil || beforeID != nil {
                        Button("查看更早消息") { Task { await load(older: true) } }
                            .frame(maxWidth: .infinity, minHeight: 44).disabled(loading)
                    }
                    if messages.isEmpty && !loading {
                        MobileEmpty(symbol: "hand.wave", title: "打个招呼吧", detail: "聊聊它喜欢的公园，或约好下次散步。")
                    }
                    ForEach(messages) { message in
                        HStack {
                            if message.isFromMe { Spacer(minLength: 40) }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(message.body).textSelection(.enabled)
                                if let date = message.createdAt {
                                    Text(date, style: .time).font(.caption).foregroundStyle(theme.muted)
                                }
                            }.padding(14)
                                .background(message.isFromMe ? theme.accentSoft : theme.surface,
                                            in: RoundedRectangle(cornerRadius: 18))
                            if !message.isFromMe { Spacer(minLength: 40) }
                        }
                    }
                    if loading { ProgressView().frame(maxWidth: .infinity) }
                }.padding(20)
            }.refreshable { await load(older: false) }.defaultScrollAnchor(.bottom)
            VStack(spacing: 10) {
                MobileErrorText(text: error)
                if pending != nil && !sending {
                    Button("重试发送") { Task { await send() } }.frame(minHeight: 44)
                }
                HStack(alignment: .bottom, spacing: 12) {
                    TextField("说点什么…", text: $draft, axis: .vertical).lineLimit(1...5)
                        .padding(12).background(theme.surface, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityIdentifier("messageInput")
                        .disabled(pending != nil || sending)
                    Button { Task { await send() } } label: {
                        if sending { ProgressView() }
                        else { Image(systemName: "arrow.up").font(.headline) }
                    }.frame(width: 48, height: 48).background(theme.accentSoft, in: Circle())
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending || draft.count > 2000)
                        .accessibilityLabel("发送消息").accessibilityIdentifier("sendMessage")
                }
                if draft.count > 2000 { Text("消息最多 2000 字").font(.caption).foregroundStyle(theme.danger) }
                if pending != nil && !sending {
                    Button("取消此次发送") { pending = nil }.font(.callout).frame(minHeight: 44)
                }
            }.padding(16).background(theme.background)
        }.background(theme.background)
            .navigationTitle(contact.pet?.name ?? "宠友").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Menu {
                    if contact.userPublicRef != nil {
                        Button("拉黑此用户", role: .destructive) { confirmingBlock = true }
                    }
                } label: { Label("更多", systemImage: "ellipsis.circle") }
            }
            .confirmationDialog("拉黑后将停止双方联系，并从附近隐藏彼此。", isPresented: $confirmingBlock) {
                Button("拉黑", role: .destructive) { Task { await block() } }
                Button("取消", role: .cancel) {}
            }
            .task {
                await load(older: false)
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(8)) } catch { break }
                    if !sending && !loading { await load(older: false, quiet: true) }
                }
            }
    }

    private func merge(_ values: [ChatMessage]) {
        var index = Dictionary(uniqueKeysWithValues: messages.map { ($0.messageId, $0) })
        for value in values { index[value.messageId] = value }
        messages = index.values.sorted {
            if $0.createdAt == $1.createdAt { return $0.messageId < $1.messageId }
            return ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
        }
    }
    private func load(older: Bool, quiet: Bool = false) async {
        guard let service = store.messages else { return }
        if !quiet { loading = true; error = nil }
        defer { loading = false }
        do {
            let page = try await service.messages(contactId: contact.contactId, before: older ? before : nil,
                                                   beforeId: older ? beforeID : nil, limit: 30)
            let wasEmpty = messages.isEmpty
            var accumulated = page.items
            if !older && !wasEmpty {
                let known = Set(messages.map(\.messageId))
                var current = page
                // If more than one page arrived, bridge the gap before publishing the new head.
                while !current.items.contains(where: { known.contains($0.messageId) }) && current.hasMore {
                    try Task.checkCancellation()
                    let next = try await service.messages(contactId: contact.contactId,
                                                          before: current.nextBefore,
                                                          beforeId: current.nextBeforeId, limit: 30)
                    if next.items.isEmpty { break }
                    accumulated += next.items
                    current = next
                }
            }
            guard !Task.isCancelled else { return }
            merge(accumulated)
            if older || wasEmpty { before = page.nextBefore; beforeID = page.nextBeforeId }
        } catch {
            if !store.handleSessionError(error) && !quiet { self.error = store.friendly(error) }
        }
    }
    private func send() async {
        guard let service = store.messages else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if pending == nil { pending = (UUID().uuidString, text) }
        guard let pending, !pending.body.isEmpty else { return }
        sending = true; error = nil
        defer { sending = false }
        do {
            let message = try await service.send(contactId: contact.contactId, body: pending.body, clientId: pending.id)
            merge([message]); self.pending = nil; draft = ""
        } catch { if !store.handleSessionError(error) { self.error = store.friendly(error) } }
    }
    private func block() async {
        guard let ref = contact.userPublicRef else { return }
        do { try await store.contacts?.block(publicRef: ref); dismiss() }
        catch { if !store.handleSessionError(error) { self.error = store.friendly(error) } }
    }
}
