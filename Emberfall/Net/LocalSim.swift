import Foundation

// MARK: - LocalSim
//
// The OFFLINE game. When Henry's server isn't connected (no sign-in, no
// network), Emberfall Kingdom is fully playable as a local PvE game: city
// building, resource accrual with idle progress, troop training, research,
// frost-node marches with locally-resolved battles, commander summoning with
// pity, quests, and the welcome track.
//
// IMPORTANT SCOPE RULE: this sim only ever runs offline. When online, the
// server is authoritative and the client never computes outcomes —
// LocalSim is not consulted. The local battle resolver mirrors the server
// formula from SERVER_DESIGN §3.3 so the two games feel consistent, but
// local results never leave the device.

@MainActor
final class LocalSim: ObservableObject {

    // MARK: - Persisted state

    struct ResourceState: Codable {
        var amount: Double
        var ratePerSec: Double
        var cap: Double
        var updatedAt: Date
    }
    struct BuildingRec: Codable, Identifiable {
        var id: String
        var type: String
        var level: Int
        var slot: Int
        var state: String
    }
    struct QueueRec: Codable, Identifiable {
        var id: String
        var kind: String        // build | train | research
        var refId: String       // building id (build) or "" (train)
        var label: String
        var extra: String       // build: "type:targetLevel" | train: "tier:infantry,cavalry,archers,siege"
        var startsAt: Date
        var endsAt: Date
    }
    struct NodeRec: Codable, Identifiable {
        var id: String
        var x: Int
        var y: Int
        var level: Int
        var name: String
        var amount: Int
        var defeated: Bool
        var weakened: Bool
    }
    struct MarchRec: Codable, Identifiable {
        var id: String
        var troops: [String: Int]
        var tier: Int
        var nodeId: String
        var departsAt: Date
        var arrivesAt: Date
        var returning: Bool
        var returnsAt: Date?
    }
    struct QuestRec: Codable, Identifiable {
        var id: String
        var progress: Int
        var claimed: Bool
    }

    struct State: Codable {
        var resources: [String: ResourceState]
        var buildings: [BuildingRec]
        var buildQueues: [QueueRec]
        var trainQueues: [QueueRec]
        var researchQueue: QueueRec?
        var troops: [String: [String: Int]]
        var research: [String]
        var commanders: [Commander]
        var pity: Int
        var inventory: [String: Int]
        var nodes: [NodeRec]
        var marches: [MarchRec]
        var reports: [BattleReport]
        var quests: [QuestRec]
        var questDay: String
        var welcomeClaimed: [Int]
        var welcomeStart: Date
        var lossesByLevel: [String: Int]
        var reliefOfferedFor: [String]
        var lastSeenAt: Date
        var onboardingStep: Int
        var onboardingDone: Bool
        var cityName: String
    }

    let config = GameConfig.bundled()
    private(set) var state: State
    private let saveURL: URL
    private var timer: Timer?

    static let gridSize = 8
    static let wildsSize = 24
    static let cityTile = (x: 12, y: 12)

    // MARK: - Lifecycle

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        saveURL = dir.appendingPathComponent("emberfall_local.json")
        if let data = try? Data(contentsOf: saveURL),
           let s = try? EmberJSON.decoder.decode(State.self, from: data) {
            state = s
        } else {
            state = LocalSim.freshState()
        }
        tick() // catch up on everything that finished while away
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    static func freshState() -> State {
        let cfg = GameConfig.bundled()
        guard let starter = cfg.starter else {
            fatalError("Bundled offline configuration requires starter resources")
        }
        let now = Date()
        var resources: [String: ResourceState] = [:]
        for kind in ResourceKind.allCases {
            let rate = cfg.production.baseRatePerSec[kind.rawValue] ?? 0.2
            let cap = Double(cfg.production.baseCap)
            let amt: Double
            switch kind {
            case .wood: amt = Double(starter.wood)
            case .stone: amt = Double(starter.stone)
            case .food: amt = Double(starter.food)
            case .gold: amt = Double(starter.gold)
            }
            resources[kind.rawValue] = ResourceState(amount: amt, ratePerSec: rate, cap: cap, updatedAt: now)
        }
        var troops: [String: [String: Int]] = ["1": [:], "2": [:], "3": [:]]
        for (t, n) in starter.troops { troops["1"]?[t] = n }
        var nodes: [NodeRec] = []
        let theme = ThemePack.active
        var rng = SeededRNG(seed: 12345)
        for i in 0..<14 {
            let level = 1 + (i / 4)
            let x = 2 + rng.next(upper: wildsSize - 4)
            let y = 2 + rng.next(upper: wildsSize - 4)
            if abs(x - cityTile.x) + abs(y - cityTile.y) < 4 { continue }
            nodes.append(NodeRec(
                id: "node-\(i)", x: x, y: y, level: level,
                name: theme.enemy.nodeNames[i % theme.enemy.nodeNames.count],
                amount: 60 * level, defeated: false, weakened: false))
        }
        return State(
            resources: resources,
            buildings: [BuildingRec(id: "citadel-0", type: "citadel", level: 1, slot: 27, state: "active")],
            buildQueues: [], trainQueues: [], researchQueue: nil,
            troops: troops, research: [],
            commanders: [], pity: cfg.summon.pityEpic,
            inventory: ["speedup_15m": 2],
            nodes: nodes, marches: [], reports: [],
            quests: LocalSim.dailyQuests().map { QuestRec(id: $0, progress: 0, claimed: false) },
            questDay: LocalSim.dayString(now),
            welcomeClaimed: [], welcomeStart: now,
            lossesByLevel: [:], reliefOfferedFor: [],
            lastSeenAt: now, onboardingStep: 0, onboardingDone: false,
            cityName: ThemePack.active.cityName)
    }

    func save() {
        state.lastSeenAt = Date()
        if let data = state.jsonData() { try? data.write(to: saveURL) }
    }

    // MARK: - Idle progress ("While you were away…")

    /// Gains accrued since `since`, per resource. Used for the away sheet.
    func awayGains(since: Date) -> [(ResourceKind, Double)] {
        var before: [ResourceKind: Double] = [:]
        for kind in ResourceKind.allCases {
            before[kind] = state.resources[kind.rawValue]?.amount ?? 0
        }
        tick()
        var out: [(ResourceKind, Double)] = []
        for kind in ResourceKind.allCases {
            let gained = (state.resources[kind.rawValue]?.amount ?? 0) - (before[kind] ?? 0)
            if gained > 1 { out.append((kind, gained)) }
        }
        return out
    }

    // MARK: - Tick (1s): accrue, complete queues, move marches

    func tick() {
        let now = Date()
        for kind in ResourceKind.allCases {
            guard var r = state.resources[kind.rawValue] else { continue }
            accrue(&r)
            state.resources[kind.rawValue] = r
        }
        // Build queues
        for q in state.buildQueues where q.endsAt <= now {
            completeBuild(q)
        }
        state.buildQueues.removeAll { $0.endsAt <= now }
        // Train queues
        for q in state.trainQueues where q.endsAt <= now {
            completeTrain(q)
        }
        state.trainQueues.removeAll { $0.endsAt <= now }
        // Research
        if let q = state.researchQueue, q.endsAt <= now {
            state.research.append(q.refId)
            state.researchQueue = nil
            bumpQuest("research")
        }
        // Marches
        for m in state.marches {
            if !m.returning, m.arrivesAt <= now {
                resolveMarch(m)
            } else if m.returning, let ret = m.returnsAt, ret <= now {
                state.marches.removeAll { $0.id == m.id }
            }
        }
        // Daily quest reset
        if state.questDay != LocalSim.dayString(now) {
            state.questDay = LocalSim.dayString(now)
            state.quests = LocalSim.dailyQuests().map { QuestRec(id: $0, progress: 0, claimed: false) }
        }
        save()
        objectWillChange.send()
    }

    private func accrue(_ r: inout ResourceState) {
        let now = Date()
        let dt = max(0, now.timeIntervalSince(r.updatedAt))
        r.amount = min(r.cap, r.amount + r.ratePerSec * dt)
        r.updatedAt = now
    }

    // MARK: - Build

    func buildCost(type: BuildingKey, level: Int) -> LevelCost? {
        var cost = config.cost(building: type, level: level)
        if state.research.contains("masonry"), var c = cost {
            c = LevelCost(wood: Int(Double(c.wood) * 0.9), stone: Int(Double(c.stone) * 0.9),
                          food: Int(Double(c.food) * 0.9), gold: Int(Double(c.gold) * 0.9), seconds: c.seconds)
            cost = c
        }
        return cost
    }

    func canAfford(_ cost: LevelCost) -> Bool {
        (state.resources["wood"]?.amount ?? 0) >= Double(cost.wood)
            && (state.resources["stone"]?.amount ?? 0) >= Double(cost.stone)
            && (state.resources["food"]?.amount ?? 0) >= Double(cost.food)
            && (state.resources["gold"]?.amount ?? 0) >= Double(cost.gold)
    }

    private func spend(_ cost: LevelCost) {
        let now = Date()
        for (k, v) in [("wood", cost.wood), ("stone", cost.stone), ("food", cost.food), ("gold", cost.gold)] {
            if var r = state.resources[k] { r.amount = max(0, r.amount - Double(v)); r.updatedAt = now; state.resources[k] = r }
        }
    }

    /// First building ever is instant (onboarding generosity); citadel speeds all builds.
    private func buildSeconds(base: Int) -> Int {
        let citadel = state.buildings.first { $0.type == "citadel" }?.level ?? 1
        return max(5, Int(Double(base) * (1.0 - 0.05 * Double(citadel - 1))))
    }

    @discardableResult
    func build(type: BuildingKey, slot: Int) -> Bool {
        guard state.buildQueues.count < 2 else { return false }
        let existing = state.buildings.first { $0.slot == slot }
        let targetLevel = (existing?.level ?? 0) + 1
        guard let cost = buildCost(type: type, level: targetLevel), canAfford(cost) else { return false }
        spend(cost)
        let now = Date()
        let instant = state.buildings.count <= 1 && state.buildQueues.isEmpty
        let seconds = instant ? 0 : buildSeconds(base: cost.seconds)
        let theme = ThemePack.active
        let rec: BuildingRec
        if let e = existing {
            rec = e
        } else {
            rec = BuildingRec(id: UUID().uuidString, type: type.rawValue, level: 0, slot: slot, state: "building")
            state.buildings.append(rec)
        }
        if seconds == 0 {
            if let i = state.buildings.firstIndex(where: { $0.id == rec.id }) {
                state.buildings[i].level = targetLevel
                state.buildings[i].state = "active"
            }
            applyProduction()
            bumpQuest("build")
        } else {
            let q = QueueRec(id: UUID().uuidString, kind: "build", refId: rec.id,
                             label: "\(theme.building(type).name) → Lv \(targetLevel)",
                             extra: "\(type.rawValue):\(targetLevel)",
                             startsAt: now, endsAt: now.addingTimeInterval(Double(seconds)))
            state.buildQueues.append(q)
            if let i = state.buildings.firstIndex(where: { $0.id == rec.id }) {
                state.buildings[i].state = "building"
            }
        }
        save(); objectWillChange.send()
        return true
    }

    private func completeBuild(_ q: QueueRec) {
        let parts = q.extra.split(separator: ":")
        guard parts.count == 2, let level = Int(parts[1]) else { return }
        if let i = state.buildings.firstIndex(where: { $0.id == q.refId }) {
            state.buildings[i].level = level
            state.buildings[i].state = "active"
        }
        applyProduction()
        bumpQuest("build")
    }

    func cancelBuild(queueId: String) {
        guard let q = state.buildQueues.first(where: { $0.id == queueId }) else { return }
        // Generous: full refund.
        let parts = q.extra.split(separator: ":")
        if parts.count == 2, let level = Int(parts[1]),
           let type = BuildingKey(rawValue: String(parts[0])),
           let cost = config.cost(building: type, level: level) {
            refund(cost)
        }
        state.buildQueues.removeAll { $0.id == queueId }
        if let i = state.buildings.firstIndex(where: { $0.id == q.refId && $0.level == 0 }) {
            state.buildings.remove(at: i)
        } else if let i = state.buildings.firstIndex(where: { $0.id == q.refId }) {
            state.buildings[i].state = "active"
        }
        save(); objectWillChange.send()
    }

    private func refund(_ cost: LevelCost) {
        let now = Date()
        for (k, v) in [("wood", cost.wood), ("stone", cost.stone), ("food", cost.food), ("gold", cost.gold)] {
            if var r = state.resources[k] { r.amount = min(r.cap, r.amount + Double(v)); r.updatedAt = now; state.resources[k] = r }
        }
    }

    /// Applies a speedup item (or free ad speedup) to a queue. Returns remaining seconds.
    @discardableResult
    func speedup(queueId: String, minutes: Int = 15) -> Bool {
        guard var q = (state.buildQueues + state.trainQueues).first(where: { $0.id == queueId }) else { return false }
        let now = Date()
        q.endsAt = min(q.endsAt, now.addingTimeInterval(TimeInterval(-minutes * 60)))
        if q.endsAt <= now { q.endsAt = now }
        if let i = state.buildQueues.firstIndex(where: { $0.id == queueId }) { state.buildQueues[i] = q }
        if let i = state.trainQueues.firstIndex(where: { $0.id == queueId }) { state.trainQueues[i] = q }
        if let rq = state.researchQueue, rq.id == queueId { state.researchQueue = q }
        bumpQuest("speedup")
        tick(); save(); objectWillChange.send()
        return true
    }

    func useSpeedupItem(queueId: String) -> Bool {
        guard (state.inventory["speedup_15m"] ?? 0) > 0 else { return false }
        state.inventory["speedup_15m"]! -= 1
        return speedup(queueId: queueId, minutes: 15)
    }

    private func applyProduction() {
        let now = Date()
        for kind in ResourceKind.allCases {
            guard var r = state.resources[kind.rawValue] else { continue }
            let producer: BuildingKey? = {
                switch kind { case .wood: return .lumber; case .stone: return .quarry; case .food: return .farm; case .gold: return .goldmint }
            }()
            let level = state.buildings.first { $0.type == producer?.rawValue }?.level ?? 0
            var rate = (config.production.baseRatePerSec[kind.rawValue] ?? 0.2)
                * (1.0 + config.production.ratePerLevel * Double(level))
            var cap = Double(config.production.baseCap + config.production.capPerLevel * level)
            if kind == .food, state.research.contains("harvest") { rate *= 1.15 }
            if kind != .food, state.research.contains("iron_tools") { rate *= 1.10 }
            if kind == .gold, state.research.contains("iron_tools") { rate *= 1.10 }
            r.ratePerSec = rate; r.cap = cap; r.updatedAt = now
            state.resources[kind.rawValue] = r
        }
    }

    // MARK: - Train

    func maxTier() -> Int {
        if state.research.contains("inferno_arms") { return 3 }
        if state.research.contains("tier2_arms") { return 2 }
        return 1
    }

    @discardableResult
    func train(troops: [TroopType: Int], tier: Int) -> Bool {
        guard tier <= maxTier() else { return false }
        let total = troops.values.reduce(0, +)
        guard total > 0, total <= 500 else { return false }
        var cost = LevelCost(wood: 0, stone: 0, food: 0, gold: 0, seconds: 0)
        for (t, n) in troops {
            guard let s = config.troopStats(t) else { return false }
            cost = LevelCost(wood: cost.wood, stone: cost.stone,
                             food: cost.food + (s.cost["food"] ?? 0) * n,
                             gold: cost.gold + (s.cost["gold"] ?? 0) * n,
                             seconds: cost.seconds + s.secondsPerUnit * n)
        }
        var seconds = cost.seconds
        if state.research.contains("medicine") { seconds = Int(Double(seconds) * 0.85) }
        let barracks = state.buildings.first { $0.type == "barracks" }?.level ?? 0
        if barracks > 0 { seconds = Int(Double(seconds) * (1.0 - 0.04 * Double(barracks))) }
        guard canAfford(cost) else { return false }
        spend(cost)
        let now = Date()
        let theme = ThemePack.active
        let desc = troops.map { "\(n2($0.value))× \(theme.troop($0.key).name)" }.joined(separator: ", ")
        let q = QueueRec(id: UUID().uuidString, kind: "train", refId: "",
                         label: "\(desc) (\(theme.tierName(tier)))",
                         extra: "\(tier):" + TroopType.allCases.map { "\($0.rawValue)=\(troops[$0] ?? 0)" }.joined(separator: ","),
                         startsAt: now, endsAt: now.addingTimeInterval(Double(max(5, seconds))))
        state.trainQueues.append(q)
        save(); objectWillChange.send()
        return true
    }

    private func completeTrain(_ q: QueueRec) {
        let parts = q.extra.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let tier = Int(parts[0]) else { return }
        var dict = state.troops[String(tier)] ?? [:]
        for pair in parts[1].split(separator: ",") {
            let kv = pair.split(separator: "=")
            if kv.count == 2, let n = Int(kv[1]) { dict[String(kv[0])] = (dict[String(kv[0])] ?? 0) + n }
        }
        state.troops[String(tier)] = dict
        bumpQuest("train")
    }

    // MARK: - Research

    func researchCost(key: String) -> LevelCost? { config.researchCost(key: key) }

    @discardableResult
    func startResearch(key: String) -> Bool {
        guard !state.research.contains(key), state.researchQueue == nil,
              let cost = researchCost(key: key), canAfford(cost) else { return false }
        if key == "tier2_arms" {
            guard (state.buildings.first { $0.type == "academy" }?.level ?? 0) >= 3 else { return false }
        }
        if key == "inferno_arms" {
            guard (state.buildings.first { $0.type == "academy" }?.level ?? 0) >= 5,
                  state.research.contains("tier2_arms") else { return false }
        }
        spend(cost)
        let now = Date()
        let theme = ThemePack.active
        state.researchQueue = QueueRec(id: UUID().uuidString, kind: "research", refId: key,
                                      label: theme.research(key)?.name ?? key,
                                      extra: key, startsAt: now,
                                      endsAt: now.addingTimeInterval(Double(cost.seconds)))
        save(); objectWillChange.send()
        return true
    }

    // MARK: - Marches & battles (offline)

    func launchMarch(troops: [TroopType: Int], tier: Int, nodeId: String) -> Bool {
        guard let node = state.nodes.first(where: { $0.id == nodeId && !$0.defeated }) else { return false }
        // Deduct troops from city
        var dict = state.troops[String(tier)] ?? [:]
        for (t, n) in troops {
            guard (dict[t.rawValue] ?? 0) >= n, n > 0 else { return false }
        }
        for (t, n) in troops { dict[t.rawValue] = (dict[t.rawValue] ?? 0) - n }
        state.troops[String(tier)] = dict
        let slowest = troops.keys.compactMap { config.troopStats($0)?.speedTilesPerMin }.min() ?? 6
        var speed = slowest
        if state.research.contains("scouting") { speed *= 1.10 }
        let dist = Double(abs(node.x - Self.cityTile.x) + abs(node.y - Self.cityTile.y))
        let minutes = max(0.25, dist / speed)
        let now = Date()
        var strDict: [String: Int] = [:]
        for (t, n) in troops { strDict[t.rawValue] = n }
        state.marches.append(MarchRec(id: UUID().uuidString, troops: strDict, tier: tier, nodeId: nodeId,
                                      departsAt: now, arrivesAt: now.addingTimeInterval(minutes * 60),
                                      returning: false, returnsAt: nil))
        save(); objectWillChange.send()
        return true
    }

    func recallMarch(id: String) {
        guard let i = state.marches.firstIndex(where: { $0.id == id }), !state.marches[i].returning else { return }
        // Troops turn around: return them immediately (generous offline rule).
        returnTroops(state.marches[i])
        state.marches.remove(at: i)
        save(); objectWillChange.send()
    }

    private func returnTroops(_ m: MarchRec) {
        var dict = state.troops[String(m.tier)] ?? [:]
        for (t, n) in m.troops { dict[t] = (dict[t] ?? 0) + n }
        state.troops[String(m.tier)] = dict
    }

    private func resolveMarch(_ m: MarchRec) {
        guard let node = state.nodes.first(where: { $0.id == m.nodeId }) else { return }
        let theme = ThemePack.active
        let tierMult: [Int: Double] = [1: 1.0, 2: 1.6, 3: 2.5]
        // Attacker power
        var atk: Double = 0
        var atkCounts: [String: Int] = [:]
        for (t, n) in m.troops {
            guard let type = TroopType(rawValue: t), let s = config.troopStats(type) else { continue }
            atk += Double(n) * Double(s.basePower) * (tierMult[m.tier] ?? 1.0)
            atkCounts[t] = n
        }
        // Triangle bonuses vs the node's mixed garrison (approx: node fields all types)
        atk *= 1.0
        if state.research.contains("war_drills") { atk *= 1.10 }
        // Node power: scripted garrison scaled by level
        let garrison = 8 + 6 * node.level
        let nodeBase = 9.0
        var def = Double(garrison) * nodeBase * (1.0 + 0.12 * Double(node.level))
        if node.weakened { def *= 0.7 }
        // Siege bonus vs fortified nodes
        if let siege = atkCounts["siege"], siege > 0 {
            atk += Double(siege) * Double(config.troopStats(.siege)?.basePower ?? 30) * 0.5
        }
        let r = atk / max(1, atk + def)
        var rng = SeededRNG(seed: UInt64(bitPattern: Int64(m.id.hashValue)))
        let jitter = 0.9 + rng.nextDouble() * 0.2
        let atkLossPct = min(0.95, (0.05 + 0.65 * (1 - r)) * jitter)
        let defLossPct = min(1.0, (0.05 + 0.65 * r) * jitter)
        let victory = r > 0.5

        var atkLosses: [String: Int] = [:]
        var survivors: [String: Int] = [:]
        for (t, n) in m.troops {
            let lost = Int((Double(n) * atkLossPct).rounded())
            atkLosses[t] = lost
            survivors[t] = max(0, n - lost)
        }
        // Survivors return home
        var dict = state.troops[String(m.tier)] ?? [:]
        for (t, n) in survivors { dict[t] = (dict[t] ?? 0) + n }
        state.troops[String(m.tier)] = dict

        var loot: [String: Int] = [:]
        if victory {
            if let i = state.nodes.firstIndex(where: { $0.id == node.id }) {
                state.nodes[i].defeated = true
            }
            state.lossesByLevel[String(node.level)] = 0
            let per = node.amount / 2
            loot = ["wood": per, "food": per]
            grant(["wood": per, "food": per])
            bumpQuest("battle")
        } else {
            let key = String(node.level)
            state.lossesByLevel[key] = (state.lossesByLevel[key] ?? 0) + 1
            offerReliefIfNeeded(level: node.level)
        }
        let report = BattleReport(
            id: UUID().uuidString, createdAt: Date(),
            outcome: victory ? "victory" : "defeat",
            title: "\(node.name) — Level \(node.level)",
            summary: victory ? theme.enemy.victoryLine : theme.enemy.defeatLine,
            attackerLosses: atkLosses,
            defenderLosses: ["frost": Int(Double(garrison) * defLossPct)],
            loot: loot.isEmpty ? nil : loot)
        state.reports.insert(report, at: 0)
        state.reports = Array(state.reports.prefix(50))
        // March returns
        if let i = state.marches.firstIndex(where: { $0.id == m.id }) {
            state.marches[i].returning = true
            let back = m.arrivesAt.timeIntervalSince(m.departsAt)
            state.marches[i].returnsAt = Date().addingTimeInterval(min(back, 300))
        }
        save(); objectWillChange.send()
    }

    /// Difficulty relief: after 2 consecutive losses at a node level, scouts
    /// find a weakened (easier) pack. Generous, never punishing.
    private func offerReliefIfNeeded(level: Int) {
        let key = String(level)
        guard (state.lossesByLevel[key] ?? 0) >= 2,
              !state.reliefOfferedFor.contains(key), level > 1 else { return }
        state.reliefOfferedFor.append(key)
        let theme = ThemePack.active
        state.nodes.append(NodeRec(
            id: UUID().uuidString,
            x: Self.cityTile.x + 3, y: Self.cityTile.y - 3,
            level: level - 1, name: theme.enemy.nodeNames.randomElement() ?? theme.enemy.fallbackNodeName,
            amount: 40 * (level - 1), defeated: false, weakened: true))
    }

    func addSpeedups(_ n: Int) {
        state.inventory["speedup_15m", default: 0] += n
        save(); objectWillChange.send()
    }

    func grant(_ amounts: [String: Int]) {
        let now = Date()
        for (k, v) in amounts {
            if var r = state.resources[k] { r.amount = min(r.cap, r.amount + Double(v)); r.updatedAt = now; state.resources[k] = r }
        }
    }

    // MARK: - Summon (offline gacha with pity)

    func summon(count: Int) -> [Commander] {
        let theme = ThemePack.active
        var out: [Commander] = []
        var rng = SeededRNG(seed: UInt64(Date().timeIntervalSince1970) ^ 0x9E3779B9)
        for _ in 0..<count {
            state.pity -= 1
            let roll = rng.nextDouble()
            let rarity: CommanderRarity
            if state.pity <= 0 {
                rarity = .epic; state.pity = config.summon.pityEpic
            } else if roll < (config.summon.rates["epic"] ?? 0.05) {
                rarity = .epic; state.pity = config.summon.pityEpic
            } else if roll < (config.summon.rates["epic"] ?? 0.05) + (config.summon.rates["rare"] ?? 0.25) {
                rarity = .rare
            } else {
                rarity = .common
            }
            let pool = theme.commanderPool(rarity: rarity)
            let name = pool.randomElement() ?? "Warden"
            let c = Commander(id: UUID().uuidString, key: name, level: 1, xp: 0,
                              stars: rarity == .epic ? 5 : rarity == .rare ? 3 : 1,
                              rarity: rarity.rawValue)
            state.commanders.append(c)
            out.append(c)
        }
        bumpQuest("summon")
        save(); objectWillChange.send()
        return out
    }

    // MARK: - Quests / welcome

    /// Grants guaranteed-epic commanders (e.g. the Warden's Cache bundle).
    /// Follows the summon convention: pity resets on every epic pull.
    func summonEpics(count: Int) -> [Commander] {
        let theme = ThemePack.active
        var out: [Commander] = []
        for _ in 0..<count {
            let pool = theme.commanderPool(rarity: .epic)
            let name = pool.randomElement() ?? "Warden"
            let c = Commander(id: UUID().uuidString, key: name, level: 1, xp: 0,
                              stars: 5, rarity: CommanderRarity.epic.rawValue)
            state.commanders.append(c)
            out.append(c)
            state.pity = config.summon.pityEpic
        }
        bumpQuest("summon")
        save(); objectWillChange.send()
        return out
    }

    static func dailyQuests() -> [String] { ["build", "train", "battle", "summon", "speedup", "research"] }

    static func dayString(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }

    func questTitle(_ id: String) -> String {
        switch id {
        case "build": return "Raise a building"
        case "train": return "Train 10 troops"
        case "battle": return "Win a battle"
        case "summon": return "Recruit a commander"
        case "speedup": return "Use a speedup"
        case "research": return "Research a technology"
        default: return id
        }
    }

    func questTarget(_ id: String) -> Int {
        switch id {
        case "train": return 10
        default: return 1
        }
    }

    private func bumpQuest(_ id: String, by n: Int = 1) {
        guard let i = state.quests.firstIndex(where: { $0.id == id }) else { return }
        state.quests[i].progress = min(questTarget(id), state.quests[i].progress + n)
    }

    func claimQuest(_ id: String) -> Bool {
        guard let i = state.quests.firstIndex(where: { $0.id == id }),
              !state.quests[i].claimed, state.quests[i].progress >= questTarget(id) else { return false }
        state.quests[i].claimed = true
        grant(["gold": 150, "wood": 100])
        save(); objectWillChange.send()
        return true
    }

    /// Generous welcome track: day N is claimable once day N-1 is claimed and
    /// at least N-1 days passed since start. Missed days never expire.
    func welcomeDays() -> [WelcomeDay] {
        let days = Int(Date().timeIntervalSince(state.welcomeStart) / 86400) + 1
        return (1...7).map { d in
            let reward: [String: Int]
            switch d {
            case 1: reward = ["wood": 300, "food": 300]
            case 2: reward = ["gold": 300]
            case 3: reward = ["speedup_15m": 2]
            case 4: reward = ["stone": 500, "wood": 500]
            case 5: reward = ["gold": 800]
            case 6: reward = ["speedup_15m": 3]
            default: reward = ["gold": 1500]
            }
            let prevClaimed = d == 1 || state.welcomeClaimed.contains(d - 1)
            return WelcomeDay(id: d, reward: reward,
                              claimed: state.welcomeClaimed.contains(d),
                              available: !state.welcomeClaimed.contains(d) && prevClaimed && d <= max(days, 1))
        }
    }

    func claimWelcome(day: Int) -> Bool {
        guard welcomeDays().first(where: { $0.id == day })?.available == true else { return false }
        state.welcomeClaimed.append(day)
        let reward = welcomeDays().first(where: { $0.id == day })?.reward ?? [:]
        for (k, v) in reward {
            if k == "speedup_15m" { state.inventory[k, default: 0] += v }
            else { grant([k: v]) }
        }
        save(); objectWillChange.send()
        return true
    }

    // MARK: - Snapshot for UI

    func snapshot() -> CitySnapshot {
        tick()
        var res: [ResourceKind: ResourceView] = [:]
        for kind in ResourceKind.allCases {
            if let r = state.resources[kind.rawValue] {
                res[kind] = ResourceView(kind: kind, amount: r.amount, cap: r.cap, ratePerSec: r.ratePerSec, updatedAt: r.updatedAt)
            }
        }
        let buildings = state.buildings.map { b -> BuildingView in
            let end = state.buildQueues.first { $0.refId == b.id }?.endsAt
            return BuildingView(id: b.id, type: BuildingKey(rawValue: b.type) ?? .citadel,
                                level: b.level, slot: b.slot, state: b.state, endsAt: end)
        }
        var troops: [Int: [TroopType: Int]] = [:]
        for (tierStr, dict) in state.troops {
            guard let tier = Int(tierStr) else { continue }
            var inner: [TroopType: Int] = [:]
            for (t, n) in dict { if let type = TroopType(rawValue: t) { inner[type] = n } }
            troops[tier] = inner
        }
        let buildQ = state.buildQueues.map { q in QueueView(id: q.id, kind: "build", label: q.label, endsAt: q.endsAt, startsAt: q.startsAt) }
        let trainQ = state.trainQueues.map { q in QueueView(id: q.id, kind: "train", label: q.label, endsAt: q.endsAt, startsAt: q.startsAt) }
        return CitySnapshot(resources: res, buildings: buildings, troops: troops,
                            power: power(), buildQueues: buildQ, trainQueues: trainQ,
                            research: Set(state.research), cityId: "local", cityName: state.cityName)
    }

    func power() -> Int {
        let tierMult: [Int: Double] = [1: 1.0, 2: 1.6, 3: 2.5]
        var p = 0
        for (tierStr, dict) in state.troops {
            let mult = tierMult[Int(tierStr) ?? 1] ?? 1.0
            for (t, n) in dict {
                if let type = TroopType(rawValue: t), let s = config.troopStats(type) {
                    p += Int(Double(n * s.basePower) * mult)
                }
            }
        }
        p += state.buildings.reduce(0) { $0 + $1.level * 10 }
        p += state.commanders.reduce(0) { $0 + $1.stars * 50 }
        return p
    }

    func nodeViews() -> [NodeView] {
        state.nodes.map { NodeView(id: $0.id, x: $0.x, y: $0.y, level: $0.level, name: $0.name, amount: $0.amount, defeated: $0.defeated) }
    }

    func marchViews() -> [MarchView] {
        state.marches.map { m in
            var t: [TroopType: Int] = [:]
            for (k, v) in m.troops { if let type = TroopType(rawValue: k) { t[type] = v } }
            let node = state.nodes.first { $0.id == m.nodeId }
            return MarchView(id: m.id, troops: t, tier: m.tier, tx: node?.x ?? 0, ty: node?.y ?? 0,
                             purpose: "attack", departsAt: m.departsAt, arrivesAt: m.arrivesAt,
                             status: m.returning ? "returning" : "marching")
        }
    }

    func reportViews() -> [BattleReport] { state.reports }

    // MARK: - Onboarding

    func advanceOnboarding() {
        state.onboardingStep += 1
        if state.onboardingStep >= 3 { state.onboardingDone = true }
        save(); objectWillChange.send()
    }

    func skipOnboarding() {
        state.onboardingDone = true
        save(); objectWillChange.send()
    }

    func resetOnboarding() {
        state.onboardingDone = false
        state.onboardingStep = 0
        save(); objectWillChange.send()
    }

    func resetAll() {
        state = Self.freshState()
        save(); objectWillChange.send()
    }
}

// MARK: - Deterministic RNG (stable node/battle generation)

struct SeededRNG {
    private var s: UInt64
    init(seed: UInt64) { s = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        s ^= s >> 12; s ^= s << 25; s ^= s >> 27
        return s &* 2685821657736338717
    }
    mutating func next(upper: Int) -> Int { Int(next() % UInt64(max(1, upper))) }
    mutating func nextDouble() -> Double { Double(next() % 1_000_000) / 1_000_000.0 }
}

private func n2(_ n: Int) -> String { "\(n)" }
