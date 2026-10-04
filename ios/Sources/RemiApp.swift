import SwiftUI
import UniformTypeIdentifiers

@main
struct RemiApp: App {
    @StateObject private var store = Store()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).tint(Color(red: 0.13, green: 0.46, blue: 0.35))
                .onChange(of: phase) { _, value in
                    if value != .active && !store.wakeEnabled { store.cancelRecording() }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        Group {
            if store.signedIn {
                TabView {
                    ChatView().tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                    TodayView().tabItem { Label("Hôm nay", systemImage: "sun.max") }
                    RecordsView().tabItem { Label("Đã lưu", systemImage: "tray.full") }
                    InboxView().tabItem { Label("Nhắc việc", systemImage: "bell") }
                    SettingsView().tabItem { Label("Cài đặt", systemImage: "gearshape") }
                }
                .task { store.run { try await store.reload() } }
            } else { LoginView() }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if store.wakeEnabled {
                Label(store.wakeStatus, systemImage: "mic.fill").font(.caption).padding(8)
                    .frame(maxWidth: .infinity).background(Color.green.opacity(0.12))
            }
            if store.busy { ProgressView("Đang xử lý…").padding(8).frame(maxWidth: .infinity).background(.regularMaterial) }
            if let notice = store.notice {
                Text(notice).font(.callout).padding(12).frame(maxWidth: .infinity).background(Color.green.opacity(0.12))
                    .onTapGesture { store.notice = nil }
            }
        }
        .alert("Remi", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("Đóng", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}

struct LoginView: View {
    @EnvironmentObject var store: Store
    @State private var email = ""
    @State private var password = ""
    @State private var register = false
    @State private var passwordAgain = ""
    @State private var consent = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "leaf.circle.fill").font(.system(size: 60)).foregroundStyle(.tint)
                        Text("Chào bạn, mình là Remi.").font(.largeTitle.bold())
                        Text("Nói điều bạn cần nhớ. Cùng Remi sắp xếp một ngày nhẹ nhàng hơn.").foregroundStyle(.secondary)
                    }.padding(.vertical, 16)
                }
                Section("Kết nối backend thử nghiệm") {
                    TextField("API HTTPS …/api/v1", text: $store.config.api)
                    TextField("Supabase project URL", text: $store.config.auth)
                    TextField("Supabase publishable key", text: $store.config.publicKey)
                }.textInputAutocapitalization(.never).autocorrectionDisabled()
                Section(register ? "Tạo tài khoản" : "Đăng nhập") {
                    TextField("Email", text: $email).keyboardType(.emailAddress).textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Mật khẩu", text: $password).textContentType(register ? .newPassword : .password)
                    if register {
                        SecureField("Nhập lại mật khẩu", text: $passwordAgain).textContentType(.newPassword)
                        Toggle("Tôi đồng ý gửi dữ liệu cho Remi xử lý và lưu sau khi xác nhận", isOn: $consent)
                    }
                    Button(register ? "Đăng ký" : "Đăng nhập") {
                        guard email.contains("@"), email.split(separator: "@").count == 2,
                              email.split(separator: "@").last?.contains(".") == true else {
                            store.error = "Vui lòng nhập email hợp lệ."; return
                        }
                        if register && (password.count < 8 || password != passwordAgain || !consent) {
                            store.error = "Mật khẩu cần ít nhất 8 ký tự, khớp xác nhận và cần đồng ý xử lý dữ liệu."; return
                        }
                        store.authenticate(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password, register: register)
                        password = ""; passwordAgain = ""
                    }.disabled(store.busy || email.isEmpty || password.isEmpty)
                    Toggle("Tôi muốn tạo tài khoản", isOn: $register)
                }
                Section { Text("Chỉ nhập publishable key. Token cá nhân được lưu trong Keychain. Cần API và Auth cùng môi trường.").font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle("Remi")
        }
    }
}

struct ChatView: View {
    @EnvironmentObject var store: Store
    @State private var text = ""
    @State private var history = false
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if store.turns.isEmpty {
                            ContentUnavailableView("Bạn muốn ghi nhớ điều gì?", systemImage: "bubble.left", description: Text("Thử: Mai 9 giờ họp với nhóm, hôm nay chi 50 nghìn tiền ăn."))
                        }
                        ForEach(store.turns) { turn in
                            HStack {
                                if turn.role == "user" { Spacer(minLength: 28) }
                                Text(.init(turn.text)).textSelection(.enabled).padding(14)
                                    .background(turn.role == "user" ? Color.green.opacity(0.14) : Color(.secondarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 18))
                                if turn.role != "user" { Spacer(minLength: 28) }
                            }.id(turn.id)
                            ForEach(turn.references) { reference in
                                NavigationLink { RecordFetchView(id: reference.value["record_id"].string) } label: {
                                    Label(reference.title, systemImage: "link").font(.caption)
                                }
                            }
                        }
                        ForEach(store.proposals) { ProposalView(item: $0) }
                        Color.clear.frame(height: 1).id("end")
                    }.padding()
                }
                .onChange(of: store.turns.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: store.recoveredVoiceText) { old, value in
                    if let value { text = value }
                    else if let old, text == old { text = "" }
                }
                .refreshable { store.run { try await store.reload() } }
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 8) {
                        if store.recording { Text("Đang thu âm · tối đa 5 phút").font(.caption).foregroundStyle(.red) }
                        HStack(alignment: .bottom, spacing: 12) {
                            Button {
                                if store.recording { store.run { try await store.finishRecording() } }
                                else { store.run { try await store.startRecording() } }
                            } label: { Image(systemName: store.recording ? "stop.circle.fill" : "mic.circle.fill").font(.title) }
                                .accessibilityLabel(store.recording ? "Dừng và gửi lời nói" : "Bắt đầu thu âm")
                            TextField("Nhắn Remi…", text: $text, axis: .vertical).lineLimit(1...5)
                                .padding(10).background(Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 16))
                            Button {
                                let message = text
                                store.run {
                                    try await store.send(message, voice: store.recoveredVoiceText == message)
                                    if text == message { text = "" }; store.recoveredVoiceText = nil
                                }
                            } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                                .accessibilityLabel("Gửi tin nhắn")
                                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.recording)
                        }.disabled(store.busy)
                        if store.recording { Button("Hủy thu âm", role: .cancel) { store.cancelRecording() }.disabled(store.busy) }
                    }.padding().background(.bar)
                }
            }
            .navigationTitle("Remi").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { history = true } label: { Image(systemName: "clock.arrow.circlepath") }.accessibilityLabel("Lịch sử hội thoại").disabled(store.busy) }
                ToolbarItem(placement: .topBarTrailing) { Button { store.newConversation() } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("Hội thoại mới").disabled(store.busy || store.recording) }
            }
            .sheet(isPresented: $history) { HistoryView() }
        }
    }
}

struct ProposalView: View {
    @EnvironmentObject var store: Store
    let item: Item
    @State private var editing = false
    @State private var confirming = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(item.value["operation"].string) · \(item.value["domain"].string)", systemImage: "checkmark.seal").font(.caption).foregroundStyle(.secondary)
            Text(item.title).font(.headline)
            if !item.value["clarification_question"].string.isEmpty {
                Text(item.value["clarification_question"].string).foregroundStyle(.orange)
            }
            PayloadView(value: item.value["payload"])
            if !item.value["missing_fields"].array.isEmpty {
                Text("Cần bổ sung: " + item.value["missing_fields"].array.map(\.string).joined(separator: ", ")).foregroundStyle(.orange)
            }
            if !item.value["ambiguous_fields"].array.isEmpty {
                Text("Cần làm rõ: " + item.value["ambiguous_fields"].array.map(\.string).joined(separator: ", ")).foregroundStyle(.orange)
            }
            Text("Nguồn: \(item.value["source_message_id"].string) · phiên bản \(item.value["version"].int)").font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button("Sửa") { editing = true }
                Button("Từ chối", role: .destructive) { store.run { try await store.reject(item) } }
                Spacer()
                Button("Xác nhận") { confirming = true }.buttonStyle(.borderedProminent)
                    .disabled(item.value["operation"].string == "unresolved" || item.value["status"].string != "proposed" || !item.value["missing_fields"].array.isEmpty || !item.value["ambiguous_fields"].array.isEmpty)
            }.disabled(store.busy || store.recording)
        }.padding(16).background(Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 20))
        .sheet(isPresented: $editing) { PayloadEditor(item: item, record: false) }
        .confirmationDialog("Lưu đúng các trường đang hiển thị?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Xác nhận và lưu", role: item.value["operation"].string == "delete" ? .destructive : nil) {
                store.run { try await store.confirm(item) }
            }
        } message: { Text("Đề xuất \(item.id), phiên bản \(item.value["version"].int).") }
    }
}

struct PayloadView: View {
    let value: JSON
    var body: some View {
        if case .object(let fields) = value {
            ForEach(fields.keys.sorted(), id: \.self) { key in
                VStack(alignment: .leading, spacing: 3) {
                    Text(key.replacingOccurrences(of: "_", with: " ")).font(.caption).foregroundStyle(.secondary)
                    Text(fields[key]?.string.isEmpty == false ? fields[key]!.string : (fields[key]?.pretty ?? "null"))
                        .font(.callout).textSelection(.enabled)
                }
            }
        } else { Text(value.pretty).textSelection(.enabled) }
    }
}

struct PayloadEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let item: Item
    let record: Bool
    @State private var draft = ""
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Chỉnh payload JSON của bản thử nghiệm. Thay đổi bản ghi tạo đề xuất mới và cần xác nhận trong Chat.").font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $draft).font(.system(.body, design: .monospaced)).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("Lưu đề xuất") {
                    store.run {
                        let payload = try JSONDecoder().decode(JSON.self, from: Data(draft.utf8))
                        guard case .object = payload else { throw ClientError(message: "Payload phải là một JSON object.") }
                        if record { try await store.mutateRecord(item, payload: payload, delete: false) }
                        else { try await store.edit(item, payload: payload) }
                        dismiss()
                    }
                }.buttonStyle(.borderedProminent).disabled(store.busy)
            }.padding().navigationTitle("Sửa đề xuất")
                .toolbar { Button("Đóng") { dismiss() }.disabled(store.busy) }
                .onAppear { draft = item.value["payload"].pretty }
        }.interactiveDismissDisabled(store.busy)
    }
}

struct HistoryView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var deleting: Item?
    @State private var renaming: Item?
    @State private var title = ""
    var body: some View {
        NavigationStack {
            List(store.conversations) { item in
                Button(item.title) { store.run { try await store.resume(item); dismiss() } }
                    .swipeActions {
                        Button("Xóa", role: .destructive) { deleting = item }
                        Button("Đổi tên") { title = item.title; renaming = item }.tint(.blue)
                    }
            }.disabled(store.busy).navigationTitle("Hội thoại")
                .toolbar { Button("Đóng") { dismiss() } }
                .task { store.run { store.conversations = try await store.api.request("/chat/conversations?limit=100&offset=0").array.map(Item.init) } }
                .alert("Xóa lịch sử hội thoại?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                    Button("Xóa", role: .destructive) { if let item = deleting { store.run { try await store.deleteConversation(item) } }; deleting = nil }
                    Button("Hủy", role: .cancel) { deleting = nil }
                } message: { Text("Các bản ghi đã xác nhận được giữ lại.") }
                .alert("Đổi tên hội thoại", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                    TextField("Tên", text: $title)
                    Button("Lưu") {
                        if let item = renaming { store.run {
                            _ = try await store.api.request("/chat/conversations/\(item.id)", method: "PATCH", body: .body(["title": .string(title)]))
                            try await store.reload()
                        } }; renaming = nil
                    }
                    Button("Hủy", role: .cancel) { renaming = nil }
                }
        }
    }
}

struct TodayView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        NavigationStack {
            List {
                Section("Hôm nay") {
                    ForEach(store.dashboard["today"].array.map(Item.init)) { item in NavigationLink { RecordView(item: item) } label: { RecordRow(item: item) } }
                    if store.dashboard["today"].array.isEmpty { Text("Chưa có việc hôm nay.").foregroundStyle(.secondary) }
                }
                Section("Sắp tới") {
                    ForEach(store.dashboard["upcoming"].array.map(Item.init)) { item in NavigationLink { RecordView(item: item) } label: { RecordRow(item: item) } }
                }
                Section("Tài chính") { PayloadView(value: store.dashboard["money"]) }
                Section("Tổng quan") { PayloadView(value: store.dashboard["counts"]) }
            }.navigationTitle("Hôm nay").refreshable { store.run { try await store.reload() } }
                .toolbar { NavigationLink { CalendarView() } label: { Image(systemName: "calendar") }.accessibilityLabel("Xem lịch") }
        }
    }
}

struct RecordRow: View {
    let item: Item
    var body: some View { VStack(alignment: .leading, spacing: 4) {
        Text(item.title).lineLimit(2)
        Text("\(item.value["domain"].string) · \(item.value["status"].string)").font(.caption).foregroundStyle(.secondary)
    } }
}

struct RecordsView: View {
    @EnvironmentObject var store: Store
    @State private var domain = ""
    @State private var search = ""
    var filtered: [Item] { store.records.filter { (domain.isEmpty || $0.value["domain"].string == domain) && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) } }
    var body: some View {
        NavigationStack {
            List {
                Picker("Loại", selection: $domain) {
                    Text("Tất cả").tag("")
                    Text("Công việc").tag("task"); Text("Lịch").tag("calendar_event")
                    Text("Ghi chú").tag("note"); Text("Chi tiêu").tag("expense"); Text("Công nợ").tag("debt")
                }
                ForEach(filtered) { item in NavigationLink { RecordView(item: item) } label: { RecordRow(item: item) } }
                if filtered.isEmpty { Text("Chưa có bản ghi phù hợp.").foregroundStyle(.secondary) }
            }.navigationTitle("Đã lưu").searchable(text: $search, prompt: "Tìm trong dữ liệu đã tải")
                .refreshable { store.run { try await store.reload() } }
                .toolbar { NavigationLink { QueryView() } label: { Label("Hỏi dữ liệu", systemImage: "magnifyingglass") } }
        }
    }
}

struct CalendarView: View {
    @EnvironmentObject var store: Store
    @State private var day = Date()
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: store.dashboard["timezone"].string) ?? TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }
    var events: [Item] {
        store.records.filter { item in
            guard item.value["domain"].string == "calendar_event" else { return false }
            let raw = item.value["payload"]["start_at"].string
            let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = format.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else { return false }
            return calendar.isDate(date, inSameDayAs: day)
        }
    }
    var body: some View {
        List {
            DatePicker("Ngày", selection: $day, displayedComponents: .date).datePickerStyle(.graphical)
                .environment(\.timeZone, calendar.timeZone)
            Section("Sự kiện · \(calendar.timeZone.identifier)") {
                ForEach(events) { item in NavigationLink { RecordView(item: item) } label: { RecordRow(item: item) } }
                if events.isEmpty { Text("Chưa có sự kiện ngày này.").foregroundStyle(.secondary) }
            }
        }.navigationTitle("Lịch")
    }
}

struct QueryView: View {
    @EnvironmentObject var store: Store
    @State private var question = ""
    @State private var response: JSON = .null
    var body: some View {
        Form {
            Section("Hỏi dữ liệu đã xác nhận") {
                TextField("Ví dụ: Tuần này tôi đã chi bao nhiêu?", text: $question, axis: .vertical)
                Button("Tìm câu trả lời") { store.run {
                    response = try await store.api.request("/query", method: "POST", body: .body([
                        "question": .string(question), "message_timestamp": .string(ISO8601DateFormatter().string(from: Date()))]))
                } }.disabled(store.busy || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if response != .null {
                Section("Kết quả") { Text(response["answer"].string).textSelection(.enabled) }
                Section("Bản ghi nguồn") {
                    ForEach(response["references"].array.map(Item.init)) { item in
                        NavigationLink { RecordFetchView(id: item.value["record_id"].string) } label: { Text(item.title) }
                    }
                }
            }
        }.navigationTitle("Hỏi Remi")
    }
}

struct RecordFetchView: View {
    @EnvironmentObject var store: Store
    let id: String
    @State private var item: Item?
    var body: some View {
        Group { if let item { RecordView(item: item) } else { ProgressView("Đang tải bản ghi…") } }
            .task { store.run { item = Item(try await store.api.request("/records/\(id)")) } }
    }
}

struct RecordView: View {
    @EnvironmentObject var store: Store
    let item: Item
    @State private var edit = false
    @State private var deletion = false
    @State private var source: JSON = .null
    var body: some View {
        Form {
            Section("Nội dung đã xác nhận") { PayloadView(value: item.value["payload"]) }
            Section("Truy vết") {
                PayloadView(value: item.value["source_reference"])
                Button("Xem tin nhắn nguồn") { store.run {
                    source = try await store.api.request("/sources/\(item.value["source_reference"]["source_message_id"].string)")
                } }
                if source != .null { Text(source["content"].string).textSelection(.enabled) }
            }
            Section {
                Button("Đề xuất chỉnh sửa") { edit = true }
                Button("Đề xuất xóa", role: .destructive) { deletion = true }
            }.disabled(store.busy)
        }.navigationTitle(item.title).navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $edit) { PayloadEditor(item: item, record: true) }
            .confirmationDialog("Tạo đề xuất xóa bản ghi này?", isPresented: $deletion, titleVisibility: .visible) {
                Button("Tạo đề xuất xóa", role: .destructive) { store.run { try await store.mutateRecord(item, payload: .null, delete: true) } }
            } message: { Text("Bạn cần xác nhận thẻ xóa trong Chat để thực hiện.") }
    }
}

struct InboxView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        NavigationStack {
            List {
                Section("Hộp thư trong ứng dụng") {
                    ForEach(store.notifications) { item in
                        NavigationLink { ReminderView(id: item.value["reminder_id"].string) } label: {
                            VStack(alignment: .leading) { Text(item.title); Text(item.value["created_at"].string).font(.caption).foregroundStyle(.secondary) }
                        }.swipeActions { Button("Đã đọc") { store.run {
                            _ = try await store.api.request("/notifications/\(item.id)/ack", method: "POST"); try await store.reload()
                        } } }
                    }
                    if store.notifications.isEmpty { Text("Chưa có thông báo.").foregroundStyle(.secondary) }
                }
                Section("Lịch nhắc") {
                    ForEach(store.dashboard["reminders"].array.map(Item.init)) { item in
                        NavigationLink { ReminderView(id: item.id) } label: { Text(item.value["trigger_at"].string) }
                    }
                }
                Section { Text("Bản thử nghiệm dùng hộp thư server. Chưa tích hợp APNs; không đảm bảo thông báo khi ứng dụng đóng.").font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle("Nhắc việc").refreshable { store.run { try await store.reload() } }
        }
    }
}

struct ReminderView: View {
    @EnvironmentObject var store: Store
    let id: String
    @State private var reminder: JSON = .null
    @State private var attempts: JSON = .null
    @State private var time = Date().addingTimeInterval(600)
    @State private var operation: String?
    var body: some View {
        Form {
            Section("Trạng thái từ server") { PayloadView(value: reminder) }
            Section("Đổi lịch") {
                DatePicker("Thời gian", selection: $time)
                Button("Hoãn đến thời gian này") { operation = "snooze" }
                Button("Đặt lại lịch") { operation = "reschedule" }
                Button("Hủy nhắc", role: .destructive) { operation = "cancel" }
            }.disabled(store.busy || reminder == .null)
            Section("Bằng chứng gửi") { Text(attempts.pretty).font(.caption.monospaced()).textSelection(.enabled) }
        }.navigationTitle("Chi tiết nhắc việc")
            .task { store.run { try await load() } }
            .confirmationDialog("Xác nhận thay đổi lịch nhắc?", isPresented: Binding(get: { operation != nil }, set: { if !$0 { operation = nil } }), titleVisibility: .visible) {
                Button("Xác nhận") {
                    if let op = operation { store.run {
                        var body: [String: JSON] = ["expected_version": reminder["schedule_version"]]
                        if op != "cancel" { body["trigger_at"] = .string(ISO8601DateFormatter().string(from: time)) }
                        reminder = try await store.api.request("/reminders/\(id)/\(op)", method: "POST", body: .body(body))
                        try await store.reload()
                    } }; operation = nil
                }
            } message: { Text("\(operation ?? "") · \(time.formatted())") }
    }
    private func load() async throws {
        reminder = try await store.api.request("/reminders/\(id)")
        attempts = try await store.api.request("/reminders/\(id)/attempts")
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var deletion = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Kết nối") { Text(store.config.api).font(.footnote).textSelection(.enabled) }
                Section("Hey Remi") { NavigationLink("Nghe wake word ở nền") { WakeSettingsView() } }
                Section("Quyền riêng tư") {
                    Button("Xuất dữ liệu JSON") { store.run { try await store.exportData() } }
                    if let url = store.exportURL { ShareLink("Chia sẻ bản xuất", item: url) }
                    Button("Xóa toàn bộ dữ liệu cá nhân", role: .destructive) { deletion = true }
                }
                Section { Button("Đăng xuất trên thiết bị", role: .destructive) { store.signOut() } }
                Section { Text("Remi iOS · bản thử nghiệm native SwiftUI\nKhông xác nhận ghi dữ liệu khi offline. Audio chỉ tồn tại tạm trong lúc chuyển lời nói.").font(.footnote).foregroundStyle(.secondary) }
            }.disabled(store.busy).navigationTitle("Cài đặt")
                .alert("Xóa toàn bộ dữ liệu cá nhân?", isPresented: $deletion) {
                    Button("Xóa vĩnh viễn", role: .destructive) { store.run { try await store.deleteData() } }
                    Button("Hủy", role: .cancel) { }
                } message: { Text("Xóa bản ghi trong database đang hoạt động. Không xóa tài khoản Supabase; chưa xác minh việc xóa backup bên ngoài.") }
        }
    }
}

struct WakeSettingsView: View {
    @EnvironmentObject var store: Store
    @State private var key = ""
    @State private var importing = false
    @State private var confirming = false
    var body: some View {
        Form {
            Section("Trạng thái thực tế") {
                Text(store.wakeStatus)
                if store.wakeEnabled {
                    Button("Tắt nghe và hủy bản thu", role: .destructive) { store.disableWake(); store.cancelRecording() }
                } else {
                    Button("Bật nghe Hey Remi") { confirming = true }
                }
            }
            Section("Thiết lập trên thiết bị") {
                SecureField("Picovoice AccessKey", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Nhập model Hey Remi (.ppn)") { importing = true }.disabled(store.wakeEnabled)
                Text("Model cần được tạo cho iOS, SDK v4 và từ khóa Hey Remi trong Picovoice Console. AccessKey lưu trong Keychain, không được đưa vào mã nguồn.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Khi bật nghe") {
                Text("Micro hoạt động liên tục khi chuyển app hoặc khóa màn hình. Wake word được xử lý trên thiết bị; chỉ đoạn yêu cầu sau wake word gửi đến Remi để chép lời và chat.")
                Text("Sau Hey Remi, nói yêu cầu rồi ngừng khoảng 1,5 giây. Mỗi yêu cầu tối đa 30 giây; chờ 8 giây không có lời nói sẽ quay lại nghe. Dữ liệu vẫn cần xác nhận thẻ trước khi lưu.")
                Text("Cuộc gọi, hệ thống dừng app hoặc buộc đóng app có thể ngắt nghe. Sau gián đoạn, mở Remi và bật lại. Micro liên tục có thể tốn pin; chưa có kiểm thử thực tế trên iPhone.")
            }.font(.callout)
        }.navigationTitle("Hey Remi").disabled(store.busy)
            .onAppear { key = Vault.wakeKey() ?? "" }
            .onDisappear { key = "" }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                do { try store.importWakeModel(result.get()) }
                catch { store.error = error.localizedDescription }
            }
            .confirmationDialog("Cho phép Remi nghe micro liên tục?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Bật nghe và gửi yêu cầu sau wake word") { store.run { try await store.enableWake(key: key) } }
                Button("Hủy", role: .cancel) { }
            } message: { Text("Nghe trên thiết bị kể cả khi khóa màn hình. Chỉ đoạn yêu cầu sau Hey Remi được gửi đến server. Không tự xác nhận dữ liệu.") }
    }
}
