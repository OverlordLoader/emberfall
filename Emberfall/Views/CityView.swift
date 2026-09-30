import SwiftUI

/// The city tab: resource bar, tappable 8×8 SpriteKit grid, build/train/
/// research panels, and queue rows with speedups.
struct CityView: View {
    @EnvironmentObject var game: GameState
    @State private var selectedSlot: Int?
    @State private var selectedBuilding: BuildingView?
    @State private var showTrain = false
    @State private var showResearch = false

    var body: some View {
        let theme = ThemePack.active
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ResourceBar(game: game)
                    cityGrid(theme)
                    queuesSection(theme)
                    actionButtons(theme)
                    if game.mode == .offline {
                        Text("Playing offline — your own realm, no sign-in needed.")
                            .font(.caption).foregroundColor(theme.textDim)
                    }
                }
                .padding()
            }
            .background(theme.background)
            .navigationTitle(game.snapshot?.cityName ?? theme.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selectedBuilding) { b in
                BuildingSheet(building: b)
            }
            .sheet(isPresented: Binding(
                get: { selectedSlot != nil },
                set: { if !$0 { selectedSlot = nil } }
            )) {
                if let slot = selectedSlot {
                    BuildSheet(slot: slot) { selectedSlot = nil }
                }
            }
            .sheet(isPresented: $showTrain) { TrainSheet() }
            .sheet(isPresented: $showResearch) { ResearchSheet() }
        }
    }

    private func cityGrid(_ theme: ThemePack) -> some View {
        CitySceneView(game: game) { slot in
            Haptics.tap()
            if let b = game.snapshot?.buildings.first(where: { $0.slot == slot }) {
                selectedBuilding = b
            } else {
                selectedSlot = slot
            }
        }
        .frame(height: 340)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.primary.opacity(0.25), lineWidth: 1)
        )
    }

    private func queuesSection(_ theme: ThemePack) -> some View {
        VStack(spacing: 8) {
            if let snap = game.snapshot {
                ForEach(snap.buildQueues + snap.trainQueues) { q in
                    QueueRow(queue: q, onSpeedup: {
                        // Speedups are earned free from quests and the welcome track.
                        Task { await game.speedup(queueId: q.id) }
                    }, onCancel: q.kind == "build" ? {
                        Task { await game.cancelBuild(queueId: q.id) }
                    } : nil)
                }
            }
        }
    }

    private func actionButtons(_ theme: ThemePack) -> some View {
        HStack(spacing: 12) {
            Button(action: { showTrain = true }) {
                Label("Train", systemImage: "shield.fill")
                    .frame(maxWidth: .infinity).padding()
                    .background(theme.surface).foregroundColor(theme.text)
                    .cornerRadius(12)
            }
            Button(action: { showResearch = true }) {
                Label("Research", systemImage: "book.fill")
                    .frame(maxWidth: .infinity).padding()
                    .background(theme.surface).foregroundColor(theme.text)
                    .cornerRadius(12)
            }
        }
    }
}

// MARK: - Build sheet

struct BuildSheet: View {
    @EnvironmentObject var game: GameState
    let slot: Int
    var onDone: () -> Void
    var body: some View {
        let theme = ThemePack.active
        NavigationStack {
            List {
                ForEach(BuildingKey.allCases, id: \.self) { key in
                    let def = theme.building(key)
                    let existing = game.snapshot?.buildings.first { $0.type == key }
                    let nextLevel = (existing?.level ?? 0) + 1
                    if nextLevel <= 5, let cost = game.local.buildCost(type: key, level: nextLevel) {
                        Button(action: {
                            Haptics.tap()
                            Task {
                                await game.build(type: key, slot: slot)
                                SoundManager.shared.play(.build)
                                onDone()
                            }
                        }) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: def.icon).foregroundColor(theme.primary)
                                    Text(def.name).font(.headline).foregroundColor(theme.text)
                                    if existing == nil {
                                        Text("NEW").font(.caption2).bold()
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(theme.success.opacity(0.2))
                                            .foregroundColor(theme.success)
                                            .cornerRadius(6)
                                    }
                                    Spacer()
                                    Text("Lv \(nextLevel)").font(.caption).foregroundColor(theme.gold)
                                }
                                Text(def.description).font(.caption).foregroundColor(theme.textDim)
                                CostLine(cost: cost)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Build")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDone)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Building detail sheet

struct BuildingSheet: View {
    @EnvironmentObject var game: GameState
    let building: BuildingView
    @Environment(\.dismiss) var dismiss
    var body: some View {
        let theme = ThemePack.active
        let def = theme.building(building.type)
        VStack(spacing: 12) {
            Image(systemName: def.icon).font(.largeTitle).foregroundColor(theme.primary)
            Text(def.name).font(.title2).bold().foregroundColor(theme.text)
            Text("Level \(building.level)").foregroundColor(theme.gold)
            Text(def.flavor).italic().foregroundColor(theme.textDim)
            Text(def.description).foregroundColor(theme.textDim).multilineTextAlignment(.center)
            if building.level < 5,
               let cost = game.local.buildCost(type: building.type, level: building.level + 1) {
                CostLine(cost: cost)
                ThemedButton(title: "Upgrade to Lv \(building.level + 1)") {
                    Task {
                        await game.build(type: building.type, slot: building.slot)
                        SoundManager.shared.play(.build)
                        dismiss()
                    }
                }
            } else {
                Text("Max level reached").foregroundColor(theme.textDim)
            }
            Spacer()
        }
        .padding()
        .presentationDetents([.medium])
    }
}

// MARK: - Train sheet

struct TrainSheet: View {
    @EnvironmentObject var game: GameState
    @Environment(\.dismiss) var dismiss
    @State private var counts: [TroopType: Int] = [:]
    @State private var tier = 1

    var body: some View {
        let theme = ThemePack.active
        let maxTier = game.local.maxTier()
        NavigationStack {
            VStack(spacing: 12) {
                // Tier picker (T2/T3 gated by Academy research)
                HStack {
                    ForEach(1...3, id: \.self) { t in
                        Button(action: { if t <= maxTier { tier = t; Haptics.tap() } }) {
                            Text(theme.tierName(t))
                                .font(.caption).bold()
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(t == tier ? theme.primary : theme.surface)
                                .foregroundColor(t == tier ? .white : (t <= maxTier ? theme.text : theme.textDim))
                                .cornerRadius(8)
                        }
                        .disabled(t > maxTier)
                    }
                    Spacer()
                    if game.mode == .online { ServerBadge() }
                }
                if maxTier < 3 {
                    Text("Higher tiers unlock via Academy research.")
                        .font(.caption).foregroundColor(theme.textDim)
                }
                ForEach(TroopType.allCases, id: \.self) { type in
                    let def = theme.troop(type)
                    HStack {
                        Image(systemName: def.icon).foregroundColor(theme.primary)
                            .frame(width: 28)
                        VStack(alignment: .leading) {
                            Text(def.name).foregroundColor(theme.text)
                            Text(def.description).font(.caption).foregroundColor(theme.textDim)
                        }
                        Spacer()
                        Stepper("", value: Binding(
                            get: { counts[type] ?? 0 },
                            set: { counts[type] = max(0, min(500, $0)) }
                        ), in: 0...500, step: 5)
                        .labelsHidden()
                        Text("\(counts[type] ?? 0)").font(.headline)
                            .foregroundColor(theme.text).frame(width: 44)
                    }
                    .padding(8)
                    .background(theme.surface)
                    .cornerRadius(10)
                }
                ThemedButton(title: "Train (\(total) troops)") {
                    Task {
                        await game.train(troops: counts.filter { $0.value > 0 }, tier: tier)
                        SoundManager.shared.play(.march)
                        dismiss()
                    }
                }
                .disabled(total == 0)
                Spacer()
            }
            .padding()
            .navigationTitle("Train Troops")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
    }

    private var total: Int { counts.values.reduce(0, +) }
}

// MARK: - Research sheet

struct ResearchSheet: View {
    @EnvironmentObject var game: GameState
    @Environment(\.dismiss) var dismiss
    var body: some View {
        let theme = ThemePack.active
        NavigationStack {
            List {
                ForEach(theme.research, id: \.key) { def in
                    let done = game.snapshot?.research.contains(def.key) ?? false
                    let active = game.local.state.researchQueue?.refId == def.key
                    HStack {
                        Image(systemName: def.icon)
                            .foregroundColor(done ? theme.success : theme.primary)
                            .frame(width: 28)
                        VStack(alignment: .leading) {
                            Text(def.name).foregroundColor(theme.text)
                            Text(def.description).font(.caption).foregroundColor(theme.textDim)
                            if let cost = game.local.researchCost(key: def.key), !done, !active {
                                CostLine(cost: cost)
                            }
                            if active, let q = game.local.state.researchQueue {
                                Text(fmtCountdown(to: q.endsAt)).font(.caption)
                                    .foregroundColor(theme.gold).monospacedDigit()
                            }
                        }
                        Spacer()
                        if done {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(theme.success)
                        } else if !active {
                            Button("Research") {
                                Task {
                                    await game.startResearch(key: def.key)
                                    SoundManager.shared.play(.coin)
                                }
                            }
                            .font(.caption).bold()
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(theme.primary).foregroundColor(.white)
                            .cornerRadius(8)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Academy Research")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}
