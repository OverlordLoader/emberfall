import Foundation
import SwiftUI
import AuthenticationServices

// MARK: - GameState
//
// The single source of truth for the UI. Two modes:
//
//   .offline — LocalSim. Full PvE city game, no sign-in, works on a plane.
//   .online  — Henry's server. Dumb terminal: renders server state, sends
//              intents, never computes outcomes.
//
// The UI only ever sees mode-agnostic snapshots (CitySnapshot, NodeView,
// MarchView). Features that need the server are badged in the UI.

@MainActor
final class GameState: ObservableObject {
    enum Mode: Equatable { case offline, online }

    static let shared = GameState()

    @Published private(set) var mode: Mode = .offline
    @Published var snapshot: CitySnapshot?
    @Published var nodes: [NodeView] = []
    @Published var marches: [MarchView] = []
    @Published var reports: [BattleReport] = []
    @Published var commanders: [Commander] = []
    @Published var quests: [Quest] = []
    @Published var welcomeDays: [WelcomeDay] = []
    @Published var inventory: [InventoryItem] = []
    @Published var worlds: [World] = []
    @Published var pity: Int = 30
    @Published var lastError: String?
    @Published var isBusy = false
    @Published var awaySheet: AwayGainsBox?
    @Published var onboardingDone = false
    /// Filled when a summon-10x consumable is granted offline; SummonView presents it.
    @Published var pendingSummonResults: [Commander]?

    let local = LocalSim()
    let api = APIClient.shared
    let ws = WSClient()
    let store = StoreManager.shared

    private var cityId: String?
    private var worldId: Int?
    private var pollTask: Task<Void, Never>?

    private init() {
        onboardingDone = local.state.onboardingDone
        refreshLocal()
        // Away sheet: gains since last session.
        let since = UserDefaults.standard.object(forKey: "emberfall.lastLaunch") as? Date ?? Date()
        let gains = local.awayGains(since: since)
        if !gains.isEmpty && UserDefaults.standard.bool(forKey: "emberfall.launchedBefore") {
            awaySheet = AwayGainsBox(id: UUID(), values: gains)
        }
        UserDefaults.standard.set(Date(), forKey: "emberfall.lastLaunch")
        UserDefaults.standard.set(true, forKey: "emberfall.launchedBefore")
        local.save()

        ws.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in self?.handleServerEvent(event) }
        }
    }

    // MARK: - Mode switching

    func goOnline(worldId: Int, cityId: String) {
        self.worldId = worldId
        self.cityId = cityId
        mode = .online
        UserDefaults.standard.set(worldId, forKey: "emberfall.worldId")
        UserDefaults.standard.set(cityId, forKey: "emberfall.cityId")
        ws.start()
        Task { await refreshOnline() }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await self?.refreshOnlineQuiet()
            }
        }
    }

    func goOffline() {
        pollTask?.cancel()
        ws.stop()
        api.signOut()
        mode = .offline
        refreshLocal()
    }

    // MARK: - Local refresh

    func refreshLocal() {
        onboardingDone = local.state.onboardingDone
        snapshot = local.snapshot()
        nodes = local.nodeViews()
        marches = local.marchViews()
        reports = local.reportViews()
        commanders = local.state.commanders
        pity = local.state.pity
        quests = local.state.quests.map { q in
            Quest(id: q.id, title: local.questTitle(q.id), description: "",
                  progress: q.progress, target: local.questTarget(q.id),
                  reward: ["gold": 150, "wood": 100], claimed: q.claimed)
        }
        welcomeDays = local.welcomeDays()
        inventory = local.state.inventory.map { (k, v) in
            InventoryItem(id: k, itemKey: k, name: itemDisplayName(k),
                          description: itemDisplayDescription(k), qty: v)
        }
    }

    private func itemDisplayName(_ key: String) -> String {
        switch key {
        case "speedup_15m": return "15-min Speedup"
        case "speedup_1h": return "1-hour Speedup"
        default: return key
        }
    }

    private func itemDisplayDescription(_ key: String) -> String {
        switch key {
        case "speedup_15m": return "Instantly advances a build, training, or research queue by 15 minutes."
        case "speedup_1h": return "Instantly advances a queue by 1 hour."
        default: return ""
        }
    }

    // MARK: - Online refresh (server is authoritative)

    func refreshOnline() async {
        guard mode == .online, let cityId else { return }
        let cid = cityId
        isBusy = true
        defer { isBusy = false }
        do {
            async let city = api.city(cityId)
            async let ms = api.marches()
            async let reps = api.reports()
            async let cmds = api.commanders()
            async let qs = api.quests()
            async let wel = api.welcome()
            async let inv = api.inventory()
            var (c, m, r, cm, q, w, iv) = try await (city, ms, reps, cmds, qs, wel, inv)
            if c.id == nil { c.id = cid }
            applyCity(c)
            marches = m.map(marchView(from:))
            reports = r
            commanders = cm
            quests = q
            welcomeDays = w
            inventory = iv
            // Map nodes come from the map bbox; refresh a default bbox around the city.
            if let wid = worldId {
                let map = try await api.map(world: wid, x1: 0, y1: 0, x2: 64, y2: 64)
                nodes = map.tiles.compactMap { t -> NodeView? in
                    guard t.terrain.hasPrefix("node") else { return nil }
                    return NodeView(id: "\(t.x),\(t.y)", x: t.x, y: t.y,
                                    level: t.nodeLevel ?? 1, name: nodeName(for: t),
                                    amount: t.nodeAmount, defeated: false)
                }
            }
            lastError = nil
        } catch {
            lastError = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func refreshOnlineQuiet() async { await refreshOnline() }

    private func nodeName(for tile: MapTile) -> String {
        let theme = ThemePack.active
        return theme.enemy.nodeNames[(tile.x + tile.y) % theme.enemy.nodeNames.count]
    }

    private func applyCity(_ c: CityDetail) {
        var res: [ResourceKind: ResourceView] = [:]
        for kind in ResourceKind.allCases {
            if let r = c.resources[kind.rawValue] {
                res[kind] = ResourceView(kind: kind, amount: r.amount, cap: r.cap,
                                         ratePerSec: r.ratePerSec, updatedAt: r.updatedAt)
            }
        }
        let buildings = c.buildings.map { b in
            BuildingView(id: b.id, type: BuildingKey(rawValue: b.type) ?? .citadel,
                         level: b.level, slot: b.slot, state: b.state, endsAt: nil)
        }
        var troops: [Int: [TroopType: Int]] = [:]
        for (tier, dict) in c.troops.byTier {
            var inner: [TroopType: Int] = [:]
            for (t, n) in dict { if let type = TroopType(rawValue: t) { inner[type] = n } }
            troops[tier] = inner
        }
        snapshot = CitySnapshot(resources: res, buildings: buildings, troops: troops,
                                power: c.power, buildQueues: [], trainQueues: [],
                                research: [], cityId: c.id ?? "",
                                cityName: c.name ?? ThemePack.active.cityName)
    }

    private func marchView(from m: March) -> MarchView {
        var t: [TroopType: Int] = [:]
        if let troops = m.troops {
            for (_, dict) in troops.byTier {
                for (k, v) in dict { if let type = TroopType(rawValue: k) { t[type] = (t[type] ?? 0) + v } }
            }
        }
        return MarchView(id: m.id, troops: t, tier: 1, tx: m.targetX, ty: m.targetY,
                         purpose: m.purpose, departsAt: m.departsAt, arrivesAt: m.arrivesAt,
                         status: m.status)
    }

    // MARK: - Server events (WS)

    private func handleServerEvent(_ event: ServerEvent) {
        switch event.type {
        case "city_delta":
            if var city: CityDetail = event.decode() {
                if city.id == nil { city.id = cityId }
                applyCity(city)
            }
        case "march_update", "march_resolved":
            Task { await refreshOnline() }
        case "battle_report":
            if let r: BattleReport = event.decode() {
                reports.insert(r, at: 0)
            }
            Task { await refreshOnline() }
        case "notification":
            if let n: ServerNotification = event.decode() { lastError = n.text }
        case "tile_delta":
            break // map refresh handles it on next poll
        case "error":
            break
        default:
            break
        }
    }

    // MARK: - Intents (online: server decides; offline: local sim)

    func build(type: BuildingKey, slot: Int) async {
        if mode == .offline {
            if !local.build(type: type, slot: slot) { lastError = "Can't build there right now." }
            refreshLocal()
            return
        }
        guard let cityId else { return }
        isBusy = true; defer { isBusy = false }
        do {
            _ = try await api.build(cityId: cityId, type: type, slot: slot,
                                    transactionId: store.lastTransactionId)
            store.lastTransactionId = nil
            await refreshOnline()
        } catch { lastError = (error as? APIError)?.errorDescription ?? error.localizedDescription }
    }

    func cancelBuild(queueId: String) async {
        if mode == .offline { local.cancelBuild(queueId: queueId); refreshLocal(); return }
        do { try await api.cancelBuild(queueId: queueId); await refreshOnline() }
        catch { lastError = (error as? APIError)?.errorDescription ?? error.localizedDescription }
    }

    /// Speedup: consumes a 15-min inventory speedup. Free speedups are earned
    /// from daily quests and the 7-day welcome track — the game is ad-free.
    func speedup(queueId: String) async {
        if mode == .offline {
            if !local.useSpeedupItem(queueId: queueId) {
                lastError = "No speedups left — earn more from daily quests and the welcome track."
            }
            refreshLocal()
            return
        }
        do {
            try await api.speedup(queueId: queueId, itemKey: "speedup_15m",
                                  transactionId: store.lastTransactionId)
            store.lastTransactionId = nil
            await refreshOnline()
        } catch { lastError = (error as? APIError)?.errorDescription ?? error.localizedDescription }
    }

    func train(troops: [TroopType: Int], tier: Int) async {
        if mode == .offline {
            if !local.train(troops: troops, tier: tier) { lastError = "Can't train those troops yet." }
            refreshLocal()
            return
        }
        guard let cityId else { return }
        do {
            _ = try await api.train(cityId: cityId, troops: troops, tier: tier,
                                    transactionId: store.lastTransactionId)
            store.lastTransactionId = nil
            await refreshOnline()
        } catch { lastError = (error as? APIError)?.errorDescription ?? error.localizedDescription }
    }

    func startResearch(key: String) async {
        if mode == .offline {
            if !local.startResearch(key: key) { lastError = "Research unavailable." }
            refreshLocal()
            return
        }
        lastError = "Research on the server arrives with the phase-1 server build."
    }

    func launchMarch(troops: [TroopType: Int], tier: Int, node: NodeView) async {
        if mode == .offline {
            if !local.launchMarch(troops: troops, tier: tier, nodeId: node.id) {
                lastError = "Not enough troops for that march."
            }
            refreshLocal()
            return
        }
        guard let cityId else { return }
        do {
            _ = try await api.launchMarch(originCityId: cityId, troops: troops, tier: tier,
                                          tx: node.x, ty: node.y, purpose: "attack")
            await refreshOnline()
        } catch { lastError = (error as? APIError)?.errorDescription ?? error.localizedDescription }
    }

    func recallMarch(id: String) async {
        if mode == .offline { local.recallMarch(id: id); refreshLocal(); return }
        do { try await api.recallMarch(id); await refreshOnline() }
        catch { lastError = (error as? APIError)?.errorDescription ?? error.localizedDescription }
    }

    func summon(count: Int) async -> [Commander] {
        if mode == .offline {
            let got = local.summon(count: count)
            refreshLocal()
            return got
        }
        do {
            let res = try await api.summon(count: count, transactionId: store.lastTransactionId)
            store.lastTransactionId = nil
            pity = res.pity
            await refreshOnline()
            return res.commanders
        } catch {
            lastError = (error as? APIError)?.errorDescription ?? error.localizedDescription
            return []
        }
    }

    func claimQuest(id: String) async {
        if mode == .offline { _ = local.claimQuest(id); refreshLocal(); return }
        do { try await api.claimQuest(id); await refreshOnline() }
        catch { lastError = (error as? APIError)?.errorDescription ?? error.localizedDescription }
    }

    func claimWelcome(day: Int) async {
        if mode == .offline { _ = local.claimWelcome(day: day); refreshLocal(); return }
        do { try await api.claimWelcome(day: day); await refreshOnline() }
        catch { lastError = (error as? APIError)?.errorDescription ?? error.localizedDescription }
    }

    func useItem(itemKey: String, queueId: String?) async {
        if mode == .offline {
            if itemKey.hasPrefix("speedup"), let q = queueId { _ = local.useSpeedupItem(queueId: q) }
            refreshLocal()
            return
        }
        do { try await api.useItem(itemKey: itemKey); await refreshOnline() }
        catch { lastError = (error as? APIError)?.errorDescription ?? error.localizedDescription }
    }

    // MARK: - IAP grants (consumables)

    /// Called by StoreManager after a verified consumable purchase.
    /// Offline: granted locally. Online receipt transmission and durable
    /// fulfillment are not implemented; StoreManager keeps checkout disabled.
    func grantConsumable(_ productId: String, transactionId: String) {
        store.lastTransactionId = transactionId
        if mode == .offline {
            switch productId {
            case StoreManager.speedupBundleID:
                local.addSpeedups(3)
            case StoreManager.summonEpic10ID:
                pendingSummonResults = local.summon(count: 10)
            case StoreManager.wardenBundleID:
                // Warden's Cache: large speedup bundle + 3 guaranteed epic summons.
                local.addSpeedups(8)
                pendingSummonResults = local.summonEpics(count: 3)
            default: break
            }
            refreshLocal()
        }
        // No online grant occurs here. APIClient does not transmit this ID.
        // Do not enable checkout until verified server fulfillment is wired.
    }

    // MARK: - Auth flows

    func loadWorlds() async {
        do { worlds = try await api.worlds(); lastError = nil }
        catch { lastError = (error as? APIError)?.errorDescription ?? error.localizedDescription }
    }

    func joinWorld(_ world: World) async {
        do {
            let res = try await api.joinWorld(world.id)
            goOnline(worldId: world.id, cityId: res.cityId)
        } catch { lastError = (error as? APIError)?.errorDescription ?? error.localizedDescription }
    }

    func tryRestoreSession() async {
        guard api.hasSavedSession, api.isConfigured else { return }
        do {
            try await api.refreshSession()
            if let wid = UserDefaults.standard.object(forKey: "emberfall.worldId") as? Int,
               let cid = UserDefaults.standard.string(forKey: "emberfall.cityId") {
                goOnline(worldId: wid, cityId: cid)
            }
        } catch {
            // Stay offline; the user can sign in again from Settings.
        }
    }

    func dismissAway() { awaySheet = nil }
    func clearError() { lastError = nil }

    func completeOnboarding() {
        local.skipOnboarding()
        onboardingDone = true
    }

    func replayTutorial() {
        local.resetOnboarding()
        onboardingDone = false
    }
}

// MARK: - Sign in with Apple coordinator

final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate {
    var onToken: ((String) -> Void)?
    var onError: ((String) -> Void)?

    func start() {
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = []
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.performRequests()
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = cred.identityToken,
              let token = String(data: data, encoding: .utf8) else {
            onError?("Couldn't read the Apple identity token.")
            return
        }
        onToken?(token)
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        onError?("Apple sign-in failed: \(error.localizedDescription)")
    }
}
