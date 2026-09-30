import Foundation
import SwiftUI

// MARK: - ThemePack
//
// EVERY theme string, color, and name in Emberfall Kingdom comes from a
// ThemePack decoded from a bundled JSON file (Theme/Themes/<id>.json).
// Game logic must NEVER hardcode theme strings or colors — it asks the
// theme. Adding game variant #2 is: new JSON + art + bundle ID + target
// flavor. Zero logic changes. See README "Adding a theme variant".

struct ThemePack: Decodable {
    struct Palette: Decodable {
        let background, surface, surface2: String
        let primary, primaryDeep: String
        let accent, accentDeep: String
        let gold: String
        let text, textDim: String
        let success, danger: String
    }
    struct BuildingDef: Decodable {
        let key: String
        let name: String
        let flavor: String
        let description: String
        let icon: String
    }
    struct TroopDef: Decodable {
        let name: String
        let description: String
        let icon: String
    }
    struct TierDef: Decodable {
        let tier: Int
        let name: String
    }
    struct ResearchDef: Decodable {
        let key: String
        let name: String
        let description: String
        let icon: String
    }
    struct EnemyDef: Decodable {
        let name: String
        let plural: String
        let description: String
        let nodeNames: [String]
        let fallbackNodeName: String
        let bossName: String
        let victoryLine: String
        let defeatLine: String
    }
    struct CommandersDef: Decodable {
        let title: String
        let subtitle: String
        let pools: [String: [String]]
        let rarityFlavor: [String: String]
    }
    struct TutorialDef: Decodable {
        struct Step: Decodable { let title: String; let body: String }
        let title: String
        let steps: [Step]
        let complete: String
    }
    struct QuestsDef: Decodable {
        let title: String
        let subtitle: String
        let claim: String
    }
    struct WelcomeDef: Decodable {
        let title: String
        let subtitle: String
    }
    struct AwayDef: Decodable {
        let title: String
        let body: String
    }
    struct ReliefDef: Decodable {
        let title: String
        let body: String
    }
    /// Art indirection (brief §8): every sprite the game draws is named here,
    /// never hardcoded in logic. New theme = new JSON + asset-catalog folder +
    /// bundle ID. `troops`/`enemies`/`commanders` are empty until the v2
    /// character art lands — code falls back to the current glyph path.
    struct ArtDef: Decodable {
        struct BuildingArt: Decodable {
            let sprite: String   // asset-catalog base name; stage suffix _s1.._sN appended
            let stages: Int
        }
        let buildings: [String: BuildingArt]?
        let resources: [String: String]?
        let terrain: [String: String]?
        let ui: [String: String]?
        let onboarding: [String: String]?
        let troops: [String: [String: String]]?
        let enemies: [String: String]?
        let commanders: [String: String]?
    }

    let id: String
    let displayName: String
    let tagline: String
    let cityName: String
    let palette: Palette
    let buildings: [BuildingDef]
    let troops: [String: TroopDef]
    let tiers: [TierDef]
    let research: [ResearchDef]
    let enemy: EnemyDef
    let commanders: CommandersDef
    let tutorial: TutorialDef
    let quests: QuestsDef
    let welcome: WelcomeDef
    let away: AwayDef
    let relief: ReliefDef
    let shieldStub: String
    let art: ArtDef?

    // MARK: - Loading

    /// The active theme id is chosen at build time by the target flavor
    /// (Info.plist key `EmberThemeID`, default "emberfall").
    static var active: ThemePack = ThemePack.load(
        id: Bundle.main.object(forInfoDictionaryKey: "EmberThemeID") as? String ?? "emberfall"
    )

    static func load(id: String) -> ThemePack {
        // NOTE: the Copy Bundle Resources phase copies files flat into the
        // bundle root, so no subdirectory lookup here.
        guard let url = Bundle.main.url(forResource: id, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let pack = try? JSONDecoder().decode(ThemePack.self, from: data) else {
            fatalError("ThemePack: missing or invalid Themes/\(id).json")
        }
        return pack
    }

    // MARK: - Accessors (the only way logic touches theme content)

    func building(_ key: BuildingKey) -> BuildingDef {
        buildings.first { $0.key == key.rawValue } ?? BuildingDef(
            key: key.rawValue, name: key.rawValue.capitalized,
            flavor: "", description: "", icon: "questionmark")
    }

    func troop(_ type: TroopType) -> TroopDef {
        troops[type.rawValue] ?? TroopDef(name: type.rawValue.capitalized, description: "", icon: "questionmark")
    }

    func tierName(_ tier: Int) -> String {
        tiers.first { $0.tier == tier }?.name ?? "Tier \(tier)"
    }

    func research(_ key: String) -> ResearchDef? {
        research.first { $0.key == key }
    }

    func commanderPool(rarity: CommanderRarity) -> [String] {
        commanders.pools[rarity.rawValue] ?? []
    }

    // MARK: - Art accessors (brief §8)

    /// Buildings top out at level 5 (see the build sheet cap). Visual stages
    /// map proportionally across levels so players *see* power grow — the
    /// CoC town-hall progression hook. Returns nil when the theme has no art
    /// for this building (caller renders the flat fallback style).
    static let maxBuildingLevel = 5

    func buildingSprite(_ key: BuildingKey, level: Int) -> String? {
        guard let b = art?.buildings?[key.rawValue], b.stages > 0, level > 0 else { return nil }
        let stage = min(b.stages, max(1, 1 + (level - 1) * b.stages / Self.maxBuildingLevel))
        return "\(b.sprite)_s\(stage)"
    }

    func resourceIcon(_ kind: ResourceKind) -> String? { art?.resources?[kind.rawValue] }
    func powerIcon() -> String? { art?.resources?["power"] }
    func terrain(_ key: String) -> String? { art?.terrain?[key] }
    func uiArt(_ key: String) -> String? { art?.ui?[key] }
    func onboardingArt(_ key: String) -> String? { art?.onboarding?[key] }

    // Character hooks — nil today (v2 art pending); callers keep the glyph path.
    func troopSprite(type: TroopType, tier: Int) -> String? {
        art?.troops?[type.rawValue]?[String(tier)]
    }
    func enemySprite(name: String) -> String? { art?.enemies?[name] }
    func commanderPortrait(name: String) -> String? { art?.commanders?[name] }

    func color(_ keyPath: KeyPath<Palette, String>) -> Color {
        Color(hex: palette[keyPath: keyPath])
    }

    var background: Color { color(\.background) }
    var surface: Color { color(\.surface) }
    var surface2: Color { color(\.surface2) }
    var primary: Color { color(\.primary) }
    var primaryDeep: Color { color(\.primaryDeep) }
    var accent: Color { color(\.accent) }
    var accentDeep: Color { color(\.accentDeep) }
    var gold: Color { color(\.gold) }
    var text: Color { color(\.text) }
    var textDim: Color { color(\.textDim) }
    var success: Color { color(\.success) }
    var danger: Color { color(\.danger) }
}

// MARK: - Game enums (theme-agnostic keys; display text comes from the theme)

enum BuildingKey: String, CaseIterable, Codable {
    case citadel, farm, lumber, quarry, goldmint, barracks, academy, walls

    /// Which resource this building produces (nil for non-producers).
    var resource: ResourceKind? {
        switch self {
        case .farm: return .food
        case .lumber: return .wood
        case .quarry: return .stone
        case .goldmint: return .gold
        default: return nil
        }
    }
}

enum ResourceKind: String, CaseIterable, Codable {
    case wood, stone, food, gold

    var icon: String {
        switch self {
        case .wood: return "tree.fill"
        case .stone: return "mountain.2.fill"
        case .food: return "leaf.fill"
        case .gold: return "dollarsign.circle.fill"
        }
    }
}

enum TroopType: String, CaseIterable, Codable {
    case infantry, cavalry, archers, siege
}

enum CommanderRarity: String, CaseIterable, Codable {
    case common, rare, epic
}

// MARK: - Hex color

extension Color {
    init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8) & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
