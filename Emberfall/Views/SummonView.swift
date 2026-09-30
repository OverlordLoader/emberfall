import SwiftUI

/// Commander gacha: summon 1× or 10×, visible pity counter.
/// Offline the pulls resolve locally with the same pity rules; online the
/// server rolls (never trust the client).
struct SummonView: View {
    @EnvironmentObject var game: GameState
    @State private var results: [Commander] = []
    @State private var showResults = false
    @State private var isSummoning = false

    var body: some View {
        let theme = ThemePack.active
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Image(systemName: "flame.circle.fill")
                        .font(.system(size: 56)).foregroundColor(theme.primary)
                    Text(theme.commanders.title).font(.title2).bold().foregroundColor(theme.text)
                    Text(theme.commanders.subtitle).foregroundColor(theme.textDim)
                        .multilineTextAlignment(.center)
                    pityCard(theme)
                    if game.mode == .offline {
                        Text("Offline recruiting — your pity carries over when you connect.")
                            .font(.caption).foregroundColor(theme.textDim)
                    } else {
                        HStack { ServerBadge(); Spacer() }
                    }
                    summonButtons(theme)
                    commandersList(theme)
                }
                .padding()
            }
            .background(theme.background)
            .navigationTitle("Wardens")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showResults) {
                SummonResultsView(results: results)
            }
            .onChange(of: game.pendingSummonResults?.count ?? 0) { _, _ in
                if let got = game.pendingSummonResults, !got.isEmpty {
                    results = got
                    game.pendingSummonResults = nil
                    showResults = true
                    SoundManager.shared.play(.summon)
                }
            }
        }
    }

    private func pityCard(_ theme: ThemePack) -> some View {
        HStack {
            Image(systemName: "sparkles").foregroundColor(theme.gold)
            Text("Epic guaranteed within \(game.pity) summons")
                .font(.subheadline).foregroundColor(theme.text)
            Spacer()
        }
        .padding()
        .background(theme.surface)
        .cornerRadius(12)
    }

    private func summonButtons(_ theme: ThemePack) -> some View {
        HStack(spacing: 12) {
            ThemedButton(title: "Summon 1×") {
                Task { await doSummon(count: 1) }
            }
            .disabled(isSummoning)
            ThemedButton(title: "Summon 10×") {
                Task { await doSummon(count: 10) }
            }
            .disabled(isSummoning)
        }
    }

    @MainActor
    private func doSummon(count: Int) async {
        isSummoning = true
        defer { isSummoning = false }
        let got = await game.summon(count: count)
        if !got.isEmpty {
            results = got
            showResults = true
            SoundManager.shared.play(.summon)
            Haptics.success()
        }
    }

    private func commandersList(_ theme: ThemePack) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Your wardens (\(game.commanders.count))")
            if game.commanders.isEmpty {
                Text("No wardens yet. Light the pyre above.").font(.caption).foregroundColor(theme.textDim)
            }
            ForEach(game.commanders) { c in
                HStack {
                    Image(systemName: c.rarity == "epic" ? "crown.fill" : c.rarity == "rare" ? "medal.fill" : "shield.fill")
                        .foregroundColor(c.rarity == "epic" ? theme.gold : c.rarity == "rare" ? theme.accent : theme.textDim)
                    VStack(alignment: .leading) {
                        Text(c.key).foregroundColor(theme.text)
                        Text((theme.commanders.rarityFlavor[c.rarity] ?? "").capitalized + " • Lv \(c.level)")
                            .font(.caption).foregroundColor(theme.textDim)
                    }
                    Spacer()
                    Text(String(repeating: "★", count: min(c.stars, 5)))
                        .font(.caption).foregroundColor(theme.gold)
                }
                .padding(8)
                .background(theme.surface)
                .cornerRadius(10)
            }
        }
    }
}

struct SummonResultsView: View {
    let results: [Commander]
    @Environment(\.dismiss) var dismiss
    var body: some View {
        let theme = ThemePack.active
        NavigationStack {
            List {
                ForEach(results) { c in
                    HStack {
                        Image(systemName: c.rarity == "epic" ? "crown.fill" : "sparkles")
                            .foregroundColor(c.rarity == "epic" ? theme.gold : theme.primary)
                        Text(c.key).font(.headline).foregroundColor(theme.text)
                        Spacer()
                        Text(c.rarity.capitalized).font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(rarityColor(c.rarity, theme).opacity(0.2))
                            .foregroundColor(rarityColor(c.rarity, theme))
                            .cornerRadius(8)
                    }
                    .listRowBackground(theme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle("New wardens!")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Welcome them") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func rarityColor(_ r: String, _ theme: ThemePack) -> Color {
        switch r {
        case "epic": return theme.gold
        case "rare": return theme.accent
        default: return theme.textDim
        }
    }
}
