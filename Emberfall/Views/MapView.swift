import SwiftUI

/// The Wilds tab: frost-node map, march composer, active marches with recall,
/// and battle reports. Online the map shows the shared world; offline it
/// shows your local wilds.
struct MapView: View {
    @EnvironmentObject var game: GameState
    @State private var selectedNode: NodeView?
    @State private var showReports = false

    /// Offline wilds are 24x24; the online world bbox we fetch is 64x64.
    private var extent: Int { game.mode == .offline ? 24 : 64 }

    var body: some View {
        let theme = ThemePack.active
        NavigationStack {
            VStack(spacing: 10) {
                ResourceBar(game: game)
                mapGrid(theme)
                marchesSection(theme)
            }
            .padding()
            .background(theme.background)
            .navigationTitle("The Wilds")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showReports = true }) {
                        Label("Reports", systemImage: "newspaper.fill")
                    }
                }
            }
            .sheet(item: $selectedNode) { node in
                MarchSheet(node: node)
            }
            .sheet(isPresented: $showReports) {
                ReportsView()
            }
        }
    }

    private func mapGrid(_ theme: ThemePack) -> some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 1), count: extent)
        let cell: CGFloat = extent == 24 ? 18 : 7
        return ScrollView([.horizontal, .vertical]) {
            LazyVGrid(columns: cols, spacing: 1) {
                ForEach(0..<(extent * extent), id: \.self) { i in
                    let x = i % extent, y = i / extent
                    tile(x: x, y: y, theme: theme, cell: cell)
                }
            }
            .frame(width: CGFloat(extent) * (cell + 1), height: CGFloat(extent) * (cell + 1))
        }
        .frame(height: 300)
        .cornerRadius(12)
    }

    @ViewBuilder
    private func tile(x: Int, y: Int, theme: ThemePack, cell: CGFloat) -> some View {
        let node = game.nodes.first { $0.x == x && $0.y == y && !$0.defeated }
        let isCity = game.mode == .offline && x == LocalSim.cityTile.x && y == LocalSim.cityTile.y
        Button(action: {
            if let node { Haptics.tap(); selectedNode = node }
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isCity ? theme.primary.opacity(0.5) : theme.surface)
                    .frame(width: cell, height: cell)
                if isCity {
                    Image(systemName: "crown.fill").font(.system(size: cell * 0.55)).foregroundColor(.white)
                } else if node != nil {
                    Image(systemName: "snowflake")
                        .font(.system(size: cell * 0.55))
                        .foregroundColor((node?.level ?? 1) >= 3 ? theme.accent : theme.textDim)
                }
            }
        }
        .disabled(node == nil && !isCity)
    }

    private func marchesSection(_ theme: ThemePack) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Marches")
            if game.marches.isEmpty {
                Text("No marches out. Tap a \(theme.enemy.plural) node to attack it.")
                    .font(.caption).foregroundColor(theme.textDim)
            }
            ForEach(game.marches) { m in
                HStack {
                    Image(systemName: "figure.march").foregroundColor(theme.primary)
                    VStack(alignment: .leading) {
                        Text("\(m.troops.values.reduce(0, +)) troops → (\(m.tx), \(m.ty))")
                            .font(.subheadline).foregroundColor(theme.text)
                        if m.status == "marching" || m.status == "attack" {
                            ProgressView(value: marchProgress(m))
                                .tint(theme.primary)
                        } else {
                            Text(m.status.capitalized).font(.caption).foregroundColor(theme.textDim)
                        }
                    }
                    Spacer()
                    if m.status == "marching" {
                        Button("Recall") {
                            Task { await game.recallMarch(id: m.id) }
                        }
                        .font(.caption).bold()
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(theme.surface2).foregroundColor(theme.text)
                        .cornerRadius(8)
                    }
                }
                .padding(8)
                .background(theme.surface)
                .cornerRadius(10)
            }
        }
    }

    private func marchProgress(_ m: MarchView) -> Double {
        let total = m.arrivesAt.timeIntervalSince(m.departsAt)
        guard total > 0 else { return 1 }
        return min(1, max(0, Date().timeIntervalSince(m.departsAt) / total))
    }
}

// MARK: - March composer

struct MarchSheet: View {
    @EnvironmentObject var game: GameState
    let node: NodeView
    @Environment(\.dismiss) var dismiss
    @State private var counts: [TroopType: Int] = [:]
    @State private var tier = 1

    var body: some View {
        let theme = ThemePack.active
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "snowflake").font(.largeTitle).foregroundColor(theme.accent)
                Text(node.name).font(.title3).bold().foregroundColor(theme.text)
                Text("Level \(node.level) \(theme.enemy.plural.singularized()) den")
                    .font(.caption).foregroundColor(theme.textDim)
                if game.mode == .offline,
                   let losses = game.local.state.lossesByLevel[String(node.level)], losses > 0 {
                    Text("Scouts warn this pack has beaten you \(losses)×. Bring more troops — or find an easier den.")
                        .font(.caption).foregroundColor(theme.gold)
                        .multilineTextAlignment(.center)
                }
                HStack {
                    ForEach(1...game.local.maxTier(), id: \.self) { t in
                        Button(action: { tier = t }) {
                            Text(theme.tierName(t)).font(.caption).bold()
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(t == tier ? theme.primary : theme.surface)
                                .foregroundColor(t == tier ? .white : theme.text)
                                .cornerRadius(8)
                        }
                    }
                    Spacer()
                }
                ForEach(TroopType.allCases, id: \.self) { type in
                    let def = theme.troop(type)
                    let have = game.snapshot?.troops[tier]?[type] ?? 0
                    HStack {
                        Image(systemName: def.icon).foregroundColor(theme.primary).frame(width: 28)
                        VStack(alignment: .leading) {
                            Text(def.name).foregroundColor(theme.text)
                            Text("Have \(have)").font(.caption).foregroundColor(theme.textDim)
                        }
                        Spacer()
                        Stepper("", value: Binding(
                            get: { counts[type] ?? 0 },
                            set: { counts[type] = max(0, min(have, $0)) }
                        ), in: 0...max(have, 0))
                        .labelsHidden()
                        Text("\(counts[type] ?? 0)").foregroundColor(theme.text).frame(width: 40)
                    }
                    .padding(8).background(theme.surface).cornerRadius(10)
                }
                ThemedButton(title: "March! (\(total) troops)") {
                    Task {
                        await game.launchMarch(troops: counts.filter { $0.value > 0 }, tier: tier, node: node)
                        SoundManager.shared.play(.march)
                        Haptics.heavy()
                        dismiss()
                    }
                }
                .disabled(total == 0)
                Spacer()
            }
            .padding()
            .navigationTitle("Attack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private var total: Int { counts.values.reduce(0, +) }
}

// MARK: - Battle reports

struct ReportsView: View {
    @EnvironmentObject var game: GameState
    @Environment(\.dismiss) var dismiss
    var body: some View {
        let theme = ThemePack.active
        NavigationStack {
            List {
                if game.reports.isEmpty {
                    Text("No battles yet. March on the \(theme.enemy.plural) to write history.")
                        .foregroundColor(theme.textDim)
                }
                ForEach(game.reports) { r in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: r.outcome == "victory" ? "trophy.fill" : "flag.slash.fill")
                                .foregroundColor(r.outcome == "victory" ? theme.gold : theme.danger)
                            Text(r.title).font(.headline).foregroundColor(theme.text)
                            Spacer()
                            Text(r.createdAt, style: .time).font(.caption).foregroundColor(theme.textDim)
                        }
                        Text(r.summary).font(.subheadline).foregroundColor(theme.textDim)
                        if let loot = r.loot, !loot.isEmpty {
                            HStack {
                                Image(systemName: "gift.fill").foregroundColor(theme.success)
                                Text("Loot: " + loot.map { "\($0.key) +\($0.value)" }.joined(separator: ", "))
                                    .font(.caption).foregroundColor(theme.success)
                            }
                        }
                        if let losses = r.attackerLosses, !losses.isEmpty {
                            Text("Lost: " + losses.filter { $0.value > 0 }.map { "\($0.value)× \($0.key)" }.joined(separator: ", "))
                                .font(.caption).foregroundColor(theme.danger)
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(theme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle("Battle Reports")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private extension String {
    func singularized() -> String {
        hasSuffix("s") ? String(dropLast()) : self
    }
}
