import SwiftUI

/// Daily hearth-quests, the 7-day welcome track, and the inventory
/// (speedups). Generous by design: no streaks to break, missed days never
/// expire.
struct QuestsView: View {
    @EnvironmentObject var game: GameState

    var body: some View {
        let theme = ThemePack.active
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(text: theme.quests.title)
                    Text(theme.quests.subtitle).font(.caption).foregroundColor(theme.textDim)
                    ForEach(game.quests) { q in
                        questRow(q, theme)
                    }
                    SectionTitle(text: theme.welcome.title)
                    Text(theme.welcome.subtitle).font(.caption).foregroundColor(theme.textDim)
                    welcomeTrack(theme)
                    SectionTitle(text: "Inventory")
                    inventoryList(theme)
                }
                .padding()
            }
            .background(theme.background)
            .navigationTitle("Quests")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func questRow(_ q: Quest, _ theme: ThemePack) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(q.title).foregroundColor(theme.text)
                ProgressView(value: Double(q.progress), total: Double(max(1, q.target)))
                    .tint(theme.primary)
                    .frame(width: 140)
            }
            Spacer()
            if q.claimed {
                Image(systemName: "checkmark.circle.fill").foregroundColor(theme.success)
            } else if q.progress >= q.target {
                Button(theme.quests.claim) {
                    Task { await game.claimQuest(id: q.id) }
                    SoundManager.shared.play(.coin)
                }
                .font(.caption).bold()
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(theme.gold).foregroundColor(.black)
                .cornerRadius(8)
            } else {
                Text("\(q.progress)/\(q.target)").font(.caption).foregroundColor(theme.textDim)
            }
        }
        .padding(10)
        .background(theme.surface)
        .cornerRadius(10)
    }

    private func welcomeTrack(_ theme: ThemePack) -> some View {
        VStack(spacing: 8) {
            ForEach(game.welcomeDays) { day in
                HStack {
                    Text("Day \(day.id)").bold().foregroundColor(theme.text).frame(width: 60, alignment: .leading)
                    Text(day.reward.map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
                        .font(.caption).foregroundColor(theme.textDim)
                    Spacer()
                    if day.claimed {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(theme.success)
                    } else if day.available {
                        Button(theme.quests.claim) {
                            Task { await game.claimWelcome(day: day.id) }
                            SoundManager.shared.play(.coin)
                        }
                        .font(.caption).bold()
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(theme.primary).foregroundColor(.white)
                        .cornerRadius(8)
                    } else {
                        Image(systemName: "lock.fill").foregroundColor(theme.textDim)
                    }
                }
                .padding(10)
                .background(theme.surface)
                .cornerRadius(10)
            }
        }
    }

    private func inventoryList(_ theme: ThemePack) -> some View {
        VStack(spacing: 8) {
            if game.inventory.isEmpty {
                Text("Empty. Speedups come from daily quests, the welcome track, and the shop.")
                    .font(.caption).foregroundColor(theme.textDim)
            }
            ForEach(game.inventory) { item in
                HStack {
                    Image(systemName: "timer.fill").foregroundColor(theme.gold)
                    VStack(alignment: .leading) {
                        Text(item.name).foregroundColor(theme.text)
                        Text(item.description).font(.caption).foregroundColor(theme.textDim)
                    }
                    Spacer()
                    Text("×\(item.qty)").bold().foregroundColor(theme.text)
                }
                .padding(10)
                .background(theme.surface)
                .cornerRadius(10)
            }
        }
    }
}
