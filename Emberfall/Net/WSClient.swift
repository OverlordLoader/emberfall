import Foundation

// MARK: - WSClient
//
// One persistent WebSocket per app session: /v1/ws?token=<access_jwt>.
// Client -> server: subscribe_map{bbox}, unsubscribe_map,
//                  chat_send{channel,body}, ping
// Server -> client: city_delta, tile_delta, march_update, march_resolved,
//                   battle_report, chat, notification{kind,text}, error
//
// Auto-reconnects with backoff. All callbacks hop to the main actor.

@MainActor
final class WSClient: ObservableObject {
    enum State { case disconnected, connecting, connected }

    @Published private(set) var state: State = .disconnected

    /// Server-pushed events. GameState subscribes and routes them.
    var onEvent: ((ServerEvent) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var reconnectDelay: TimeInterval = 1
    private var shouldRun = false
    private var subscribedBbox: BBox?

    struct BBox: Equatable {
        let x1, y1, x2, y2: Int
    }

    func start() {
        guard shouldRun == false else { return }
        shouldRun = true
        reconnectDelay = 1
        connect()
    }

    func stop() {
        shouldRun = false
        subscribedBbox = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .disconnected
    }

    private func connect() {
        guard shouldRun else { return }
        guard let token = APIClient.shared.wsToken, !token.isEmpty else {
            scheduleReconnect(); return
        }
        let raw = UserDefaults.standard.string(forKey: "emberfall.serverURL") ?? ""
        // Review-safe: always wss. Strip any scheme the user typed.
        let host = raw.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !host.isEmpty else { scheduleReconnect(); return }
        var comps = URLComponents()
        comps.scheme = "wss"
        comps.host = host
        comps.path = "/v1/ws"
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = comps.url else { scheduleReconnect(); return }

        state = .connecting
        let t = URLSession.shared.webSocketTask(with: url)
        task = t
        t.resume()
        // Optimistically treat open as connected; first ping confirms.
        state = .connected
        reconnectDelay = 1
        if let bbox = subscribedBbox { send(["type": "subscribe_map", "bbox": ["x1": bbox.x1, "y1": bbox.y1, "x2": bbox.x2, "y2": bbox.y2]]) }
        sendPing()
        receiveLoop()
    }

    private func scheduleReconnect() {
        guard shouldRun else { return }
        state = .disconnected
        let delay = reconnectDelay
        reconnectDelay = min(30, reconnectDelay * 2)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.connect()
        }
    }

    // MARK: - Outgoing

    func subscribeMap(_ bbox: BBox) {
        subscribedBbox = bbox
        send(["type": "subscribe_map", "bbox": ["x1": bbox.x1, "y1": bbox.y1, "x2": bbox.x2, "y2": bbox.y2]])
    }

    func unsubscribeMap() {
        subscribedBbox = nil
        send(["type": "unsubscribe_map"])
    }

    func chatSend(channel: String, body: String) {
        send(["type": "chat_send", "channel": channel, "body": body])
    }

    private func sendPing() {
        send(["type": "ping"])
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard let self, self.shouldRun, self.state == .connected else { return }
            self.sendPing()
        }
    }

    private func send(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { [weak self] error in
            if error != nil {
                Task { @MainActor [weak self] in self?.handleDrop() }
            }
        }
    }

    private func handleDrop() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        scheduleReconnect()
    }

    // MARK: - Incoming

    private func receiveLoop() {
        task?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handle(text: text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) { self.handle(text: text) }
                    @unknown default:
                        break
                    }
                    self.receiveLoop()
                case .failure:
                    self.handleDrop()
                }
            }
        }
    }

    private func handle(text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        let payload = (try? JSONSerialization.data(withJSONObject: obj["data"] as? [String: Any] ?? [:])) ?? Data()
        onEvent?(ServerEvent(type: type, payload: payload))
    }
}

// MARK: - ServerEvent

/// A raw server->client message. GameState decodes the payload per type.
struct ServerEvent {
    let type: String
    let payload: Data

    func decode<T: Decodable>(_ type: T.Type = T.self) -> T? {
        try? EmberJSON.decoder.decode(T.self, from: payload)
    }
}
