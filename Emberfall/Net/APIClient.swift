import Foundation

// MARK: - APIClient
//
// Implements the frozen REST contract (see README "Protocol notes").
// - Bearer access-JWT on every call except auth.
// - Every mutation carries an `Idempotency-Key: <uuid>` header, generated
//   per call. Retries reuse the SAME key: the server returns the stored
//   response instead of re-executing — no double-spend, ever.
// - On 401 the client refreshes once and retries transparently.
// - The client is a dumb terminal: it never computes battle outcomes,
//   resource amounts, or timers. It renders what the server returns.

enum APIError: Error, LocalizedError {
    case noServerURL
    case notSignedIn
    case http(Int, String)
    case decoding(String)
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .noServerURL: return "No kingdom server set. Add one in Settings → Kingdom Server."
        case .notSignedIn: return "Sign in to connect to the kingdom server."
        case .http(let code, let body): return "Server error (\(code)): \(body)"
        case .decoding(let what): return "Couldn't understand the server's reply (\(what))."
        case .network(let e): return e.localizedDescription
        }
    }
}

@MainActor
final class APIClient: ObservableObject {
    static let shared = APIClient()

    @Published private(set) var signedIn = false
    @Published private(set) var player: Player?

    private var accessToken: String?
    private let refreshAccount = "emberfall.refresh"

    /// The current access token for the WebSocket handshake (same module).
    var wsToken: String? { accessToken }

    private var baseURL: URL? {
        let raw = UserDefaults.standard.string(forKey: "emberfall.serverURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        let withScheme = raw.contains("://") ? raw : "https://\(raw)"
        return URL(string: withScheme + "/v1")
    }

    private init() {
        if KeychainHelper.load(account: refreshAccount) != nil {
            // Session may still be valid; GameState decides whether to refresh.
            signedIn = false
        }
    }

    var hasSavedSession: Bool {
        KeychainHelper.load(account: refreshAccount) != nil
    }

    var isConfigured: Bool { baseURL != nil }

    // MARK: - Auth

    func signInWithApple(identityToken: String) async throws {
        let res: AuthResponse = try await post("auth/apple", body: ["identity_token": identityToken], idempotent: false)
        storeSession(res)
    }

    #if DEBUG
    /// DEV/TESTFLIGHT ONLY. Hidden behind the debug settings toggle; never
    /// compiled into review builds (#if DEBUG).
    func devSignIn(deviceId: String) async throws {
        let res: AuthResponse = try await post("auth/dev", body: ["device_id": deviceId], idempotent: false)
        storeSession(res)
    }
    #endif

    func refreshSession() async throws {
        guard let refresh = KeychainHelper.load(account: refreshAccount) else {
            throw APIError.notSignedIn
        }
        let res: AuthResponse = try await post("auth/refresh", body: ["refresh": refresh], idempotent: false)
        storeSession(res)
    }

    func signOut() {
        accessToken = nil
        KeychainHelper.delete(account: refreshAccount)
        player = nil
        signedIn = false
    }

    private func storeSession(_ res: AuthResponse) {
        accessToken = res.access
        KeychainHelper.save(res.refresh, account: refreshAccount)
        player = res.player
        signedIn = true
    }

    // MARK: - Worlds

    func worlds() async throws -> [World] {
        try await get("worlds")
    }

    func joinWorld(_ id: Int) async throws -> JoinWorldResponse {
        try await post("worlds/\(id)/join", body: EmptyBody(), idempotent: true)
    }

    func worldConfig(_ id: Int) async throws -> GameConfig {
        try await get("worlds/\(id)/config")
    }

    // MARK: - City

    func city(_ id: String) async throws -> CityDetail {
        try await get("cities/\(id)")
    }

    func build(cityId: String, type: BuildingKey, slot: Int, transactionId: String? = nil) async throws -> QueueResponse {
        var body: [String: AnyEncodable] = [
            "type": AnyEncodable(type.rawValue),
            "slot": AnyEncodable(slot),
        ]
        if let t = transactionId { body["transaction_id"] = AnyEncodable(t) }
        return try await post("cities/\(cityId)/build", body: body, idempotent: true)
    }

    func cancelBuild(queueId: String) async throws {
        let _: EmptyResponse = try await post("build-queue/\(queueId)/cancel", body: EmptyBody(), idempotent: true)
    }

    func speedup(queueId: String, itemKey: String? = nil, transactionId: String? = nil) async throws -> QueueResponse {
        var body: [String: AnyEncodable] = [:]
        if let k = itemKey { body["item_key"] = AnyEncodable(k) }
        if let t = transactionId { body["transaction_id"] = AnyEncodable(t) }
        return try await post("build-queue/\(queueId)/speedup", body: body, idempotent: true)
    }

    func train(cityId: String, troops: [TroopType: Int], tier: Int, transactionId: String? = nil) async throws -> QueueResponse {
        var dict: [String: AnyEncodable] = [:]
        for (t, n) in troops { dict[t.rawValue] = AnyEncodable(n) }
        var body: [String: AnyEncodable] = ["troops": AnyEncodable(dict), "tier": AnyEncodable(tier)]
        if let t = transactionId { body["transaction_id"] = AnyEncodable(t) }
        return try await post("cities/\(cityId)/train", body: body, idempotent: true)
    }

    // MARK: - Marches

    func launchMarch(originCityId: String, troops: [TroopType: Int], tier: Int, tx: Int, ty: Int, purpose: String) async throws -> LaunchMarchResponse {
        var dict: [String: AnyEncodable] = [:]
        for (t, n) in troops { dict[t.rawValue] = AnyEncodable(n) }
        let body: [String: AnyEncodable] = [
            "origin_city_id": AnyEncodable(originCityId),
            "troops": AnyEncodable(dict),
            "tier": AnyEncodable(tier),
            "tx": AnyEncodable(tx),
            "ty": AnyEncodable(ty),
            "purpose": AnyEncodable(purpose),
        ]
        return try await post("marches", body: body, idempotent: true)
    }

    func marches() async throws -> [March] {
        try await get("marches")
    }

    func recallMarch(_ id: String) async throws {
        let _: EmptyResponse = try await post("marches/\(id)/recall", body: EmptyBody(), idempotent: true)
    }

    // MARK: - Map / reports

    func map(world: Int, x1: Int, y1: Int, x2: Int, y2: Int) async throws -> MapResponse {
        try await get("map?world=\(world)&x1=\(x1)&y1=\(y1)&x2=\(x2)&y2=\(y2)")
    }

    func reports(cursor: String? = nil) async throws -> [BattleReport] {
        let q = cursor.map { "?cursor=\($0)" } ?? ""
        struct Page: Codable { let reports: [BattleReport] }
        // The contract returns a paginated list; accept either a bare array
        // or an envelope.
        do {
            let page: Page = try await get("reports\(q)")
            return page.reports
        } catch {
            return try await get("reports\(q)")
        }
    }

    // MARK: - Commanders / quests / welcome / inventory

    func commanders() async throws -> [Commander] {
        try await get("commanders")
    }

    func summon(count: Int, transactionId: String? = nil) async throws -> SummonResult {
        var body: [String: AnyEncodable] = ["count": AnyEncodable(count)]
        if let t = transactionId { body["transaction_id"] = AnyEncodable(t) }
        return try await post("commanders/summon", body: body, idempotent: true)
    }

    func quests() async throws -> [Quest] {
        try await get("quests")
    }

    func claimQuest(_ id: String) async throws {
        let _: EmptyResponse = try await post("quests/\(id)/claim", body: EmptyBody(), idempotent: true)
    }

    func welcome() async throws -> [WelcomeDay] {
        try await get("welcome")
    }

    func claimWelcome(day: Int) async throws {
        let _: EmptyResponse = try await post("welcome/claim", body: ["day": AnyEncodable(day)], idempotent: true)
    }

    func inventory() async throws -> [InventoryItem] {
        try await get("inventory")
    }

    func useItem(itemKey: String, qty: Int = 1, transactionId: String? = nil) async throws {
        var body: [String: AnyEncodable] = [
            "item_key": AnyEncodable(itemKey),
            "qty": AnyEncodable(qty),
        ]
        if let t = transactionId { body["transaction_id"] = AnyEncodable(t) }
        let _: EmptyResponse = try await post("inventory/use", body: body, idempotent: true)
    }

    func sync(since: Date) async throws -> SyncDelta {
        let iso = ISO8601.loose.string(from: since)
        let encoded = iso.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? iso
        return try await get("sync?since=\(encoded)")
    }

    // MARK: - Alliances

    func createAlliance(worldId: Int, name: String, tag: String) async throws -> AllianceRef {
        try await post("worlds/\(worldId)/alliances",
                       body: ["name": AnyEncodable(name), "tag": AnyEncodable(tag)], idempotent: true)
    }

    func joinAlliance(_ id: Int) async throws {
        let _: EmptyResponse = try await post("alliances/\(id)/join", body: EmptyBody(), idempotent: true)
    }

    func leaveAlliance(_ id: Int) async throws {
        let _: EmptyResponse = try await post("alliances/\(id)/leave", body: EmptyBody(), idempotent: true)
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await request(path, method: "GET", body: nil as Data?, idempotencyKey: nil)
    }

    private func post<T: Decodable, B: Encodable>(_ path: String, body: B, idempotent: Bool) async throws -> T {
        let data = try EmberJSON.encoder.encode(body)
        let key = idempotent ? UUID().uuidString : nil
        return try await request(path, method: "POST", body: data, idempotencyKey: key)
    }

    private func request<T: Decodable>(_ path: String, method: String, body: Data?, idempotencyKey: String?, retried: Bool = false) async throws -> T {
        guard let base = baseURL else { throw APIError.noServerURL }
        // NOTE: query strings are split off BEFORE appending — otherwise
        // appendingPathComponent would percent-encode the '?'.
        let url: URL = {
            if let q = path.firstIndex(of: "?") {
                var comps = URLComponents(
                    url: base.appendingPathComponent(String(path[..<q])),
                    resolvingAgainstBaseURL: false)!
                comps.percentEncodedQuery = String(path[path.index(after: q)...])
                return comps.url!
            }
            return base.appendingPathComponent(path)
        }()
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("EmberfallKingdom/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        if let key = idempotencyKey {
            req.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        }
        if let token = accessToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if !path.hasPrefix("auth/") {
            throw APIError.notSignedIn
        }
        req.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.http(-1, "No response")
        }
        if http.statusCode == 401, !retried, !path.hasPrefix("auth/") {
            // One transparent refresh, then retry with the SAME idempotency key.
            try await refreshSession()
            return try await request(path, method: method, body: body, idempotencyKey: idempotencyKey, retried: true)
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw APIError.http(http.statusCode, String(text.prefix(300)))
        }
        do {
            return try EmberJSON.decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding("\(T.self): \(error.localizedDescription)")
        }
    }
}

// MARK: - Tiny helpers

struct EmptyBody: Encodable {}
struct EmptyResponse: Decodable {}
struct AllianceRef: Codable { let allianceId: Int }

/// Type-erased Encodable for building request dictionaries.
struct AnyEncodable: Encodable {
    private let encode: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T) { encode = { try value.encode(to: $0) } }
    func encode(to encoder: Encoder) throws { try encode(encoder) }
}
