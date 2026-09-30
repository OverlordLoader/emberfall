import Foundation

// MARK: - Shared JSON codecs
//
// The frozen API contract speaks snake_case JSON with ISO-8601 timestamps.
// These codecs are the single choke point for both directions.

enum EmberJSON {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let s = try container.decode(String.self)
            if let date = ISO8601.parse(s) { return date }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid ISO-8601 date: \(s)")
        }
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

enum ISO8601 {
    /// Parses ISO-8601 with or without fractional seconds.
    static let loose: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// NOTE: intentionally not an extension on ISO8601DateFormatter —
    /// redeclaring `date(from:)` there would collide with Foundation.
    static func parse(_ string: String) -> Date? {
        loose.date(from: string) ?? plain.date(from: string)
    }
}

// MARK: - Auth

struct Player: Codable {
    let id: String
    let displayName: String
}

struct AuthResponse: Codable {
    let access: String
    let refresh: String
    let player: Player
}

// MARK: - Worlds

struct World: Codable, Identifiable {
    let id: Int
    let name: String
    let status: String
    let players: Int
}

struct JoinWorldResponse: Codable {
    let cityId: String
}

// MARK: - Game config (mirrors bundled offline_config.json shape)
//
// GET /v1/worlds/{id}/config returns theme-tunable tuning. The client
// decodes it into the same shape as the offline config so online and
// offline share one cost/stats code path. Unknown extra keys are ignored.

struct LevelCost: Codable {
    let wood: Int
    let stone: Int
    let food: Int
    let gold: Int
    let seconds: Int
}

struct BuildingConfig: Codable {
    let levels: [LevelCost]
}

struct TroopStats: Codable {
    let basePower: Int
    let carry: Int
    let cost: [String: Int]      // resource -> amount
    let secondsPerUnit: Int
    let speedTilesPerMin: Double
}

struct SummonConfig: Codable {
    let pityEpic: Int
    let rates: [String: Double]
}

struct ProductionConfig: Codable {
    let baseRatePerSec: [String: Double]
    let baseCap: Int
    let ratePerLevel: Double
    let capPerLevel: Int
}

struct StarterConfig: Codable {
    let wood: Int
    let stone: Int
    let food: Int
    let gold: Int
    let troops: [String: Int]
}

struct GameConfig: Codable {
    let buildings: [String: BuildingConfig]
    let troops: [String: TroopStats]
    let production: ProductionConfig
    let researchCosts: [String: LevelCost]
    let summon: SummonConfig
    let starter: StarterConfig?

    static func bundled() -> GameConfig {
        // NOTE: the Copy Bundle Resources phase copies files flat into the
        // bundle root, so no subdirectory lookup here.
        guard let url = Bundle.main.url(forResource: "offline_config", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let cfg = try? EmberJSON.decoder.decode(GameConfig.self, from: data) else {
            fatalError("Missing or invalid Config/offline_config.json")
        }
        return cfg
    }

    func cost(building key: BuildingKey, level: Int) -> LevelCost? {
        buildings[key.rawValue]?.levels[safe: level - 1]
    }

    func researchCost(key: String) -> LevelCost? { researchCosts[key] }
    func troopStats(_ type: TroopType) -> TroopStats? { troops[type.rawValue] }
}

// MARK: - City

struct CityResource: Codable {
    var amount: Double
    var ratePerSec: Double
    var cap: Double
    var updatedAt: Date

    /// Display-only interpolation. The server recomputes authoritatively on
    /// every read; the client never uses this for spends.
    func interpolated(now: Date = Date()) -> Double {
        min(cap, amount + ratePerSec * max(0, now.timeIntervalSince(updatedAt)))
    }
}

struct BuildingState: Codable, Identifiable {
    let id: String
    let type: String
    var level: Int
    let slot: Int
    var state: String          // 'active' | 'building' | 'ruin'
}

/// Troop counts. The contract documents troops{infantry,cavalry,archers,siege};
/// tier is a separate train parameter, so the server may return either flat
/// counts or per-tier nesting. This decodes both. (See README Protocol notes.)
struct TroopCounts: Codable {
    /// tier -> type -> count. Flat responses land in tier 1.
    var byTier: [Int: [String: Int]]

    init(byTier: [Int: [String: Int]] = [:]) { self.byTier = byTier }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let flat = try? c.decode([String: Int].self) {
            byTier = [1: flat]
            return
        }
        if let nested = try? c.decode([String: [String: Int]].self) {
            var out: [Int: [String: Int]] = [:]
            for (k, v) in nested {
                let tier = Int(k.replacingOccurrences(of: "tier", with: "")
                    .replacingOccurrences(of: "t", with: "")) ?? (Int(k) ?? 1)
                out[tier] = v
            }
            byTier = out
            return
        }
        byTier = [:]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(byTier)
    }

    func count(tier: Int, type: TroopType) -> Int {
        byTier[tier]?[type.rawValue] ?? 0
    }
}

struct CityDetail: Codable {
    /// The contract doesn't explicitly promise `id`; the client passes the
    /// requested id in when the server omits it.
    var id: String?
    let name: String?
    var resources: [String: CityResource]
    var buildings: [BuildingState]
    var troops: TroopCounts
    var power: Int
}

struct QueueResponse: Codable {
    let queueId: String
    let endsAt: Date
}

struct QueueView: Codable, Identifiable {
    let id: String
    let kind: String            // "build" | "train" | "research"
    let label: String
    let endsAt: Date
    let startsAt: Date?
}

// MARK: - Marches

struct March: Codable, Identifiable {
    let id: String
    let originCityId: String?
    let targetX: Int
    let targetY: Int
    let targetCityId: String?
    let purpose: String         // attack | gather | reinforce | scout
    let status: String
    let departsAt: Date
    let arrivesAt: Date
    let returnsAt: Date?
    let troops: TroopCounts?

    /// Display-only interpolation between departure and arrival.
    func progress(now: Date = Date()) -> Double {
        let total = arrivesAt.timeIntervalSince(departsAt)
        guard total > 0 else { return 1 }
        return min(1, max(0, now.timeIntervalSince(departsAt) / total))
    }
}

struct LaunchMarchResponse: Codable {
    let marchId: String
    let departsAt: Date
    let arrivesAt: Date
}

// MARK: - Map

struct MapTile: Codable {
    let x: Int
    let y: Int
    let terrain: String
    let ownerCityId: String?
    let nodeAmount: Int?
    let nodeLevel: Int?
}

struct MapCity: Codable, Identifiable {
    let id: String
    let name: String
    let x: Int
    let y: Int
    let playerName: String?
}

struct MapResponse: Codable {
    let tiles: [MapTile]
    let cities: [MapCity]
    let marches: [March]
}

// MARK: - Reports

struct BattleReport: Codable, Identifiable {
    let id: String
    let createdAt: Date
    let outcome: String        // "victory" | "defeat"
    let title: String
    let summary: String
    let attackerLosses: [String: Int]?
    let defenderLosses: [String: Int]?
    let loot: [String: Int]?
}

// MARK: - Commanders

struct Commander: Codable, Identifiable {
    let id: String
    let key: String           // display name key from theme pool
    let level: Int
    let xp: Int
    let stars: Int
    let rarity: String        // common | rare | epic
}

struct SummonResult: Codable {
    let commanders: [Commander]
    let pity: Int              // pulls remaining until guaranteed epic
}

// MARK: - Quests / welcome / inventory

struct Quest: Codable, Identifiable {
    let id: String
    let title: String
    let description: String
    let progress: Int
    let target: Int
    let reward: [String: Int]
    let claimed: Bool
}

struct WelcomeDay: Codable, Identifiable {
    let id: Int               // day number 1...7
    let reward: [String: Int]
    let claimed: Bool
    let available: Bool
}

struct InventoryItem: Codable, Identifiable {
    let id: String
    let itemKey: String
    let name: String
    let description: String
    let qty: Int
}

// MARK: - Sync

struct SyncDelta: Codable {
    let city: CityDetail?
    let marches: [March]?
    let reports: [BattleReport]?
    let notifications: [ServerNotification]?
    let serverTime: Date?
}

struct ServerNotification: Codable, Identifiable {
    let id: String
    let kind: String
    let text: String
    let createdAt: Date?
}

// MARK: - UI-facing snapshot (mode-agnostic: online + offline both produce this)

struct ResourceView {
    let kind: ResourceKind
    var amount: Double
    var cap: Double
    var ratePerSec: Double
    var updatedAt: Date
    var interpolated: Double { min(cap, amount + ratePerSec * max(0, Date().timeIntervalSince(updatedAt))) }
}

struct BuildingView: Identifiable {
    let id: String
    let type: BuildingKey
    var level: Int
    let slot: Int
    var state: String
    var endsAt: Date?
}

struct CitySnapshot {
    var resources: [ResourceKind: ResourceView]
    var buildings: [BuildingView]
    var troops: [Int: [TroopType: Int]]
    var power: Int
    var buildQueues: [QueueView]
    var trainQueues: [QueueView]
    var research: Set<String>
    var cityId: String
    var cityName: String
}

struct NodeView: Identifiable {
    let id: String
    let x: Int
    let y: Int
    let level: Int
    let name: String
    let amount: Int?
    var defeated: Bool
}

struct MarchView: Identifiable {
    let id: String
    var troops: [TroopType: Int]
    var tier: Int
    let tx: Int
    let ty: Int
    let purpose: String
    let departsAt: Date
    let arrivesAt: Date
    var status: String
}

// MARK: - Small helpers

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension Encodable {
    func jsonData() -> Data? { try? EmberJSON.encoder.encode(self) }
}
