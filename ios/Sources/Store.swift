import SwiftUI
import AVFoundation

struct Item: Identifiable { let id: String; let value: JSON
    init(_ value: JSON) { self.value = value; id = value["id"].string.isEmpty ? value["conversation_id"].string : value["id"].string }
    var title: String {
        let p = value["payload"]
        for key in ["title", "description", "content", "counterparty"] { if !p[key].string.isEmpty { return p[key].string } }
        return value["title"].string.isEmpty ? value["domain"].string : value["title"].string
    }
}
struct Turn: Identifiable { let id = UUID(); let role: String; let text: String; var references: [Item] = [] }

@MainActor
final class Store: ObservableObject {
    @Published var config: Configuration
    @Published var signedIn = false
    @Published var busy = false
    @Published var error: String?
    @Published var notice: String?
    @Published var turns: [Turn] = []
    @Published var proposals: [Item] = []
    @Published var conversations: [Item] = []
    @Published var records: [Item] = []
    @Published var notifications: [Item] = []
    @Published var dashboard: JSON = .null
    @Published var recording = false
    @Published var exportURL: URL?
    @Published var recoveredVoiceText: String?
    @Published var wakeEnabled = false
    @Published var wakeStatus = "Đã tắt"
    private let wake = WakeWord()
    private var interruptionObserver: NSObjectProtocol?
    private(set) var api: API
    private var conversation: String?
    private var keys: [String: String] = [:]
    private var deleteKey = UUID().uuidString
    private var recorder: AVAudioRecorder?
    private var audioURL: URL?
    private var startedAt = Date()
    private var recordingTimer: Task<Void, Never>?

    init(client: API? = nil) {
        let c = UserDefaults.standard.data(forKey: "remi.config").flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) } ?? Configuration()
        config = client?.config ?? c
        let s = client == nil ? Vault.load() : client?.session
        api = client ?? API(config: c, session: s); signedIn = s != nil
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in
                self?.disableWake()
                self?.cancelRecording()
                self?.wakeStatus = "Micro bị gián đoạn. Mở Remi và bật lại khi sẵn sàng."
            }
        }
        // Raw audio is temporary and never restored; remove interrupted captures from prior runs.
        if let files = try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix("remi-voice-") || file.lastPathComponent.hasPrefix("remi-export-") { try? FileManager.default.removeItem(at: file) }
        }
    }
    func run(_ operation: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil; notice = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await operation() }
            catch { self.error = error.localizedDescription }
        }
    }
    func authenticate(email: String, password: String, register: Bool) {
        run {
            try self.config.validate()
            let client = API(config: self.config, session: nil)
            if register {
                _ = try await client.auth("signup", body: .body(["email": .string(email), "password": .string(password)]))
                self.notice = "Đã gửi yêu cầu đăng ký. Kiểm tra email xác nhận, sau đó đăng nhập."
            } else {
                try await client.signIn(email: email, password: password)
                UserDefaults.standard.set(try JSONEncoder().encode(self.config), forKey: "remi.config")
                self.api = client; self.signedIn = true
                self.turns = []; self.conversation = nil; self.proposals = []; self.keys = [:]
                try await self.reload()
            }
        }
    }
    func signOut() {
        guard !busy else { return }
        disableWake()
        cancelRecording(); Vault.clear(); api.session = nil; signedIn = false
        conversation = nil; turns = []; proposals = []; records = []; conversations = []
        notifications = []; dashboard = .null; keys = [:]; error = nil; notice = nil; recoveredVoiceText = nil
        if let url = exportURL { try? FileManager.default.removeItem(at: url) }; exportURL = nil
    }
    func reload() async throws {
        proposals = try await api.request("/actions/pending").array.map(Item.init)
        dashboard = try await api.request("/dashboard")
        conversations = try await api.request("/chat/conversations?limit=100&offset=0").array.map(Item.init)
        // Fetch every page; never present a truncated page as all owner records.
        var all: [Item] = []; var offset = 0
        while true {
            let page = try await api.request("/records?limit=100&offset=\(offset)")
            all += page["records"].array.map(Item.init)
            guard page["next_offset"] != .null else { break }
            let next = page["next_offset"].int
            guard next > offset else { throw ClientError(message: "Phân trang dữ liệu không hợp lệ.") }
            offset = next
        }
        records = all
        notifications = try await api.request("/notifications").array.map(Item.init)
    }
    func send(_ text: String, voice: Bool = false) async throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClientError(message: "Chưa có nội dung để gửi.") }
        if conversation == nil {
            let created = try await api.request("/chat/conversations", method: "POST")
            let id = created["conversation_id"].string
            guard UUID(uuidString: id) != nil else { throw ClientError(message: "Máy chủ không cấp hội thoại hợp lệ.") }
            conversation = id
        }
        let response = try await api.request("/chat/messages", method: "POST", body: .body([
            "message": .string(text), "channel": .string(voice ? "voice_transcript" : "text"),
            "conversation_id": .string(conversation!),
            "message_timestamp": .string(ISO8601DateFormatter().string(from: Date()))]))
        guard !response["assistant_message"].string.isEmpty else {
            throw ClientError(message: "Máy chủ không trả lời hợp lệ. Tin nhắn có thể đã được xử lý; kiểm tra lịch sử trước khi gửi lại.")
        }
        turns.append(Turn(role: "user", text: text))
        turns.append(Turn(role: "assistant", text: response["assistant_message"].string, references: response["references"].array.map(Item.init)))
        proposals = try await api.request("/actions/pending").array.map(Item.init)
    }
    func resume(_ item: Item) async throws {
        let result = try await api.request("/chat/conversations/\(item.id)")
        conversation = item.id
        turns = result["messages"].array.map { Turn(role: $0["role"].string, text: $0["content"].string) }
        proposals = try await api.request("/actions/pending").array.map(Item.init)
    }
    func newConversation() { guard !busy else { return }; conversation = nil; turns = [] }
    func deleteConversation(_ item: Item) async throws {
        _ = try await api.request("/chat/conversations/\(item.id)", method: "DELETE", body: .body(["confirmation": .string("delete_conversation_history")]))
        if conversation == item.id { conversation = nil; turns = [] }
        try await reload()
    }
    func edit(_ item: Item, payload: JSON) async throws {
        let result = try await api.request("/actions/\(item.id)", method: "PATCH", body: .body([
            "expected_version": item.value["version"], "payload": payload]))
        proposals = proposals.map { $0.id == item.id ? Item(result) : $0 }
    }
    func confirm(_ item: Item) async throws {
        let v = item.value
        // The key belongs to the exact review snapshot and survives ambiguous network outcomes.
        let fingerprint = item.id + v["source_message_id"].string + String(v["version"].int) + v["payload"].pretty
        let key = keys[fingerprint] ?? UUID().uuidString; keys[fingerprint] = key
        let result = try await api.request("/actions/\(item.id)/confirm", method: "POST", body: .body([
            "source_message_id": v["source_message_id"], "proposal_version": v["version"], "payload": v["payload"]]), key: key)
        guard result["status"].string == "persisted", !result["record_id"].string.isEmpty,
              !result["audit_event_id"].string.isEmpty else { throw ClientError(message: "Chưa xác minh được kết quả lưu. Thử lại cùng đề xuất.") }
        proposals.removeAll { $0.id == item.id }
        notice = "Đã xác nhận và lưu."
        try await reload()
    }
    func reject(_ item: Item) async throws {
        _ = try await api.request("/actions/\(item.id)/reject", method: "POST", body: .body(["expected_version": item.value["version"]]))
        proposals.removeAll { $0.id == item.id }
    }
    func mutateRecord(_ item: Item, payload: JSON, delete: Bool) async throws {
        let v = item.value
        let source = v["source_reference"]["source_message_id"]
        let response: JSON
        if delete {
            response = try await api.request("/actions/preview", method: "POST", body: .body([
                "source_message_id": source, "domain": v["domain"], "operation": .string("delete"),
                "target_record_id": .string(item.id), "expected_record_version": v["version"],
                "payload": .body(["domain": v["domain"], "operation": .string("delete"), "record_id": .string(item.id)])]))
        } else {
            response = try await api.request("/records/\(v["domain"].string)/\(item.id)", method: "PATCH",
                body: .body(["source_message_id": source, "expected_version": v["version"], "payload": payload]))
        }
        proposals.removeAll { $0.id == response["id"].string }; proposals.append(Item(response))
        notice = "Đề xuất đã sẵn sàng trong Chat. Xác nhận thẻ để lưu thay đổi."
    }
    func exportData() async throws {
        let result = try await api.request("/data/export")
        if let old = exportURL { try? FileManager.default.removeItem(at: old) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("remi-export-\(UUID()).json")
        try Data(result.pretty.utf8).write(to: url, options: [.atomic, .completeFileProtection])
        exportURL = url
    }
    func deleteData() async throws {
        let response = try await api.request("/data", method: "DELETE", body: .body(["confirmation": .string("delete_all_personal_data")]), key: deleteKey)
        guard response["status"].string == "deleted", !response["receipt_id"].string.isEmpty else {
            throw ClientError(message: "Chưa xác minh được kết quả xóa; hãy thử lại.")
        }
        conversation = nil; turns = []; deleteKey = UUID().uuidString
        if let url = exportURL { try? FileManager.default.removeItem(at: url) }; exportURL = nil
        try await reload(); notice = "Đã xóa dữ liệu trong cơ sở dữ liệu đang hoạt động. Tài khoản Auth vẫn còn."
    }
    static var wakeModelURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HeyRemi.ppn")
    }
    func importWakeModel(_ url: URL) throws {
        guard !wakeEnabled else { throw ClientError(message: "Tắt chế độ nghe trước khi đổi model.") }
        guard url.pathExtension.lowercased() == "ppn" else { throw ClientError(message: "Chọn file .ppn được tạo cho iOS, SDK v4 và từ khóa Hey Remi.") }
        let scope = url.startAccessingSecurityScopedResource(); defer { if scope { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty && data.count <= 10 * 1024 * 1024 else { throw ClientError(message: "Model trống hoặc vượt 10 MiB.") }
        let target = Self.wakeModelURL
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        wakeStatus = "Đã nhập model. Bật nghe để kiểm tra với SDK."
    }
    func enableWake(key: String) async throws {
        guard signedIn, !recording else { throw ClientError(message: "Đăng nhập và kết thúc bản thu hiện tại trước khi bật nghe.") }
        guard await AVAudioApplication.requestRecordPermission() else { throw ClientError(message: "Cần quyền microphone để nghe Hey Remi.") }
        guard FileManager.default.fileExists(atPath: Self.wakeModelURL.path) else { throw ClientError(message: "Chưa có model Hey Remi dành cho iOS. Nhập file .ppn trước.") }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ClientError(message: "Nhập AccessKey của Picovoice trên thiết bị; không gửi key vào chat.") }
        try Vault.saveWakeKey(key)
        wake.detected = { [weak self] in
            guard let self, self.wakeEnabled else { return }
            if self.busy { self.resumeWake(); return }
            self.wakeStatus = "Đã nghe Hey Remi. Hãy nói yêu cầu…"
            self.run { try await self.startRecording(handsFree: true) }
        }
        wake.failed = { [weak self] in
            self?.disableWake(); self?.wakeStatus = "Wake word gặp lỗi. Kiểm tra key/model rồi bật lại."
        }
        do {
            try wake.configure(key: key, modelURL: Self.wakeModelURL)
            try wake.resume(); wakeEnabled = true; wakeStatus = "Đang nghe Hey Remi trên thiết bị"
        } catch {
            disableWake()
            throw ClientError(message: "Không thể bật wake word. Kiểm tra AccessKey, model iOS v4 và quyền micro.")
        }
    }
    func disableWake() {
        wakeEnabled = false; wake.shutdown(); wakeStatus = "Đã tắt"
        if !recording { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
    private func resumeWake() {
        guard wakeEnabled, signedIn else { return }
        do { try wake.resume(); wakeStatus = "Đang nghe Hey Remi trên thiết bị" }
        catch { disableWake(); wakeStatus = "Không thể tiếp tục nghe. Mở Remi và bật lại." }
    }
    func startRecording(handsFree: Bool = false) async throws {
        guard !recording else { return }
        guard await AVAudioApplication.requestRecordPermission() else { throw ClientError(message: "Microphone chưa được cho phép. Bạn vẫn có thể nhập văn bản.") }
        wake.pause()
        let audio = AVAudioSession.sharedInstance()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("remi-voice-\(UUID()).m4a")
        audioURL = url
        do {
            try audio.setCategory(.record, mode: .default); try audio.setActive(true)
            recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
            recorder?.isMeteringEnabled = handsFree
            guard recorder?.record(forDuration: 300) == true else { throw ClientError(message: "Không thể bắt đầu thu âm.") }
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            startedAt = Date(); recording = true
            recordingTimer = Task { @MainActor in
                if handsFree {
                    var endpoint = VoiceEndpoint()
                    while !Task.isCancelled && self.recording {
                        do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                        self.recorder?.updateMeters()
                        let decision = endpoint.evaluate(elapsed: Date().timeIntervalSince(self.startedAt), db: self.recorder?.averagePower(forChannel: 0) ?? -160)
                        switch decision {
                        case .wait: continue
                        case .empty:
                            self.cancelRecording(); self.wakeStatus = "Chưa nghe yêu cầu. Đang nghe Hey Remi lại."; return
                        case .submit:
                            if self.busy { self.cancelRecording(); self.error = "Remi đang xử lý. Hãy thử lại sau khi hoàn tất." }
                            else { self.run { try await self.finishRecording() } }
                            return
                        }
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                if !Task.isCancelled { self.cancelRecording(); self.error = "Đã đạt giới hạn 5 phút. Hãy thu một đoạn ngắn hơn." }
            }
        } catch { cancelRecording(); throw error }
    }
    func cancelRecording() {
        recordingTimer?.cancel(); recordingTimer = nil; recorder?.stop(); recorder = nil; recording = false
        if let url = audioURL { try? FileManager.default.removeItem(at: url) }; audioURL = nil
        if wakeEnabled { resumeWake() }
        else { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
    func finishRecording() async throws {
        guard let url = audioURL else { return }
        let duration = min(300000, max(1, Int(Date().timeIntervalSince(startedAt) * 1000)))
        recorder?.stop()
        defer { cancelRecording() }
        let audio = try Data(contentsOf: url)
        guard !audio.isEmpty, audio.count <= 10 * 1024 * 1024 else { throw ClientError(message: "Âm thanh trống hoặc vượt 10 MiB.") }
        let boundary = UUID().uuidString
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"duration_ms\"\r\n\r\n\(duration)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"voice.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8)
        body.append(audio); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        // Resume actual microphone processing before awaiting the network in background.
        cancelRecording()
        let result = try await api.request("/voice/transcribe", method: "POST", bytes: body, contentType: "multipart/form-data; boundary=\(boundary)")
        let transcript = result["transcript"].string
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientError(message: "Không nhận được lời nói. Hãy thử lại hoặc nhập văn bản.") }
        recoveredVoiceText = transcript
        try await send(transcript, voice: true)
        recoveredVoiceText = nil
    }
}
