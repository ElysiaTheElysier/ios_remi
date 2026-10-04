import Foundation
import Security

// Preserve decimal money strings and unknown proposal fields without interpreting them.
enum JSON: Codable, Equatable {
    case object([String: JSON]), array([JSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSON].self) { self = .object(v) }
        else if let v = try? c.decode([JSON].self) { self = .array(v) }
        else { self = .number(try c.decode(Double.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> JSON { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    var string: String { if case .string(let v) = self { return v }; return "" }
    var array: [JSON] { if case .array(let v) = self { return v }; return [] }
    var int: Int { if case .number(let v) = self { return Int(v) }; return 0 }
    var pretty: String {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(data: e.encode(self), encoding: .utf8)) ?? "null"
    }
    static func body(_ fields: [String: JSON]) -> JSON { .object(fields) }
}

struct ClientError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Configuration: Codable {
    var api = ""
    var auth = ""
    var publicKey = ""
    func validate() throws {
        for value in [api, auth] {
            guard let u = URL(string: value), u.scheme == "https", u.host != nil,
                  u.user == nil, u.password == nil, u.query == nil, u.fragment == nil else {
                throw ClientError(message: "Nhập URL HTTPS hợp lệ. API cần kết thúc bằng /api/v1.")
            }
        }
        guard !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClientError(message: "Cần publishable key của Supabase; không dùng service-role key.")
        }
    }
}

struct Session: Codable {
    let access_token: String
    let refresh_token: String
    let expires_in: Int
    var storedAt: Date = Date()
    enum CodingKeys: String, CodingKey { case access_token, refresh_token, expires_in }
    var expired: Bool { Date().timeIntervalSince(storedAt) >= Double(expires_in - 60) }
}

enum Vault {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "vn.remi.experimental", kSecAttrAccount as String: "session"]
    static func load() -> Session? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        // Always refresh after launch; the serialized token response has no reliable persisted expiry time.
        var s = try? JSONDecoder().decode(Session.self, from: data)
        s?.storedAt = .distantPast
        return s
    }
    static func save(_ session: Session) throws {
        let data = try JSONEncoder().encode(session)
        let update: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ClientError(message: "Không thể lưu phiên trong Keychain.") }
    }
    static func clear() { SecItemDelete(query as CFDictionary) }
    static func wakeKey() -> String? {
        var q = query; q[kSecAttrAccount as String] = "wake-key"
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func saveWakeKey(_ value: String) throws {
        var q = query; q[kSecAttrAccount as String] = "wake-key"
        let data = Data(value.utf8)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary)
        if status == errSecItemNotFound {
            q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ClientError(message: "Không thể lưu AccessKey vào Keychain.") }
    }
}

@MainActor
final class API {
    let config: Configuration
    var session: Session?
    private var refreshTask: Task<Session, Error>?
    private let transport: URLSession
    init(config: Configuration, session: Session?, transport: URLSession = URLSession(configuration: .ephemeral)) {
        self.config = config; self.session = session; self.transport = transport
    }
    private func execute(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError(message: "Phản hồi máy chủ không hợp lệ.") }
        guard (200..<300).contains(http.statusCode) else {
            let body = try? JSONDecoder().decode(JSON.self, from: data)
            let message = body?["message"].string ?? ""
            throw ClientError(message: message.isEmpty ? "Yêu cầu thất bại (HTTP \(http.statusCode)). Hãy kiểm tra kết nối hoặc đăng nhập lại." : message)
        }
        return data
    }
    func auth(_ path: String, body: JSON) async throws -> Data {
        try config.validate()
        guard let url = URL(string: config.auth.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/auth/v1/" + path) else {
            throw ClientError(message: "URL Auth không hợp lệ.")
        }
        var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 30
        r.setValue(config.publicKey, forHTTPHeaderField: "apikey")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(body)
        return try await execute(r)
    }
    func signIn(email: String, password: String) async throws {
        let data = try await auth("token?grant_type=password", body: .body(["email": .string(email), "password": .string(password)]))
        let s = try JSONDecoder().decode(Session.self, from: data)
        try Vault.save(s); session = s
    }
    private func token() async throws -> String {
        guard let s = session else { throw ClientError(message: "Vui lòng đăng nhập.") }
        if !s.expired { return s.access_token }
        if let task = refreshTask { return try await task.value.access_token }
        let task = Task { @MainActor in
            let data = try await self.auth("token?grant_type=refresh_token", body: .body(["refresh_token": .string(s.refresh_token)]))
            return try JSONDecoder().decode(Session.self, from: data)
        }
        refreshTask = task
        defer { refreshTask = nil }
        let refreshed = try await task.value
        try Vault.save(refreshed); session = refreshed
        return refreshed.access_token
    }
    func request(_ path: String, method: String = "GET", body: JSON? = nil, key: String? = nil,
                 bytes: Data? = nil, contentType: String = "application/json") async throws -> JSON {
        try config.validate()
        guard let url = URL(string: config.api.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw ClientError(message: "URL API không hợp lệ.")
        }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData); r.httpMethod = method; r.timeoutInterval = path == "/chat/messages" ? 120 : 30
        r.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        r.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let key { r.setValue(key, forHTTPHeaderField: "Idempotency-Key") }
        r.httpBody = try bytes ?? body.map { try JSONEncoder().encode($0) }
        let data = try await execute(r)
        return data.isEmpty ? .null : try JSONDecoder().decode(JSON.self, from: data)
    }
}
