import SwiftUI

// MARK: - Shared UI helpers (all theme-driven)

struct ResourceBar: View {
    @ObservedObject var game: GameState
    var body: some View {
        let theme = ThemePack.active
        HStack(spacing: 10) {
            ForEach(ResourceKind.allCases, id: \.self) { kind in
                if let r = game.snapshot?.resources[kind] {
                    VStack(spacing: 1) {
                        HStack(spacing: 3) {
                            Image(systemName: kind.icon)
                                .font(.caption2)
                                .foregroundColor(theme.gold)
                            Text(short(r.interpolated))
                                .font(.caption2).bold()
                                .foregroundColor(theme.text)
                        }
                        Text("/ \(short(r.cap))")
                            .font(.caption2)
                            .foregroundColor(theme.textDim)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 3) {
                Image(systemName: "bolt.fill").font(.caption2).foregroundColor(theme.primary)
                Text("\(game.snapshot?.power ?? 0)")
                    .font(.caption2).bold().foregroundColor(theme.text)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(theme.surface)
        .cornerRadius(10)
    }

    private func short(_ v: Double) -> String {
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 10_000 { return String(format: "%.1fK", v / 1_000) }
        return "\(Int(v))"
    }
}

/// Badge marking features that need the kingdom server.
struct ServerBadge: View {
    var body: some View {
        let theme = ThemePack.active
        Text("SERVER")
            .font(.caption2).bold()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(theme.accentDeep)
            .foregroundColor(theme.accent)
            .cornerRadius(6)
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        let theme = ThemePack.active
        Text(text)
            .font(.headline)
            .foregroundColor(theme.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }
}

struct CostLine: View {
    let cost: LevelCost
    var body: some View {
        let theme = ThemePack.active
        HStack(spacing: 8) {
            ForEach([("wood", cost.wood), ("stone", cost.stone), ("food", cost.food), ("gold", cost.gold)], id: \.0) { k, v in
                if v > 0, let kind = ResourceKind(rawValue: k) {
                    HStack(spacing: 2) {
                        Image(systemName: kind.icon).font(.caption2)
                        Text("\(v)").font(.caption2)
                    }.foregroundColor(theme.textDim)
                }
            }
            Spacer()
            HStack(spacing: 2) {
                Image(systemName: "clock").font(.caption2)
                Text(fmtTime(cost.seconds)).font(.caption2)
            }.foregroundColor(theme.textDim)
        }
    }
}

func fmtTime(_ seconds: Int) -> String {    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    let h = seconds / 3600, m = (seconds % 3600) / 60
    return m == 0 ? "\(h)h" : "\(h)h \(m)m"
}

func fmtCountdown(to date: Date) -> String {
    let s = max(0, Int(date.timeIntervalSince(Date())))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    return "\(s / 3600)h \((s % 3600) / 60)m"
}

struct QueueRow: View {
    let queue: QueueView
    var onSpeedup: (() -> Void)?
    var onCancel: (() -> Void)?

    var body: some View {
        let theme = ThemePack.active
        HStack {
            Image(systemName: queue.kind == "build" ? "hammer.fill" : queue.kind == "train" ? "shield.fill" : "book.fill")
                .foregroundColor(theme.primary)
            VStack(alignment: .leading) {
                Text(queue.label).font(.subheadline).foregroundColor(theme.text)
                Text(fmtCountdown(to: queue.endsAt)).font(.caption).foregroundColor(theme.textDim)
                    .monospacedDigit()
            }
            Spacer()
            if let onSpeedup {
                Button("Speed up", action: onSpeedup)
                    .font(.caption).bold()
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(theme.primary)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            if let onCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle").foregroundColor(theme.textDim)
                }
            }
        }
        .padding(8)
        .background(theme.surface)
        .cornerRadius(10)
    }
}

struct ThemedButton: View {
    let title: String
    var enabled: Bool = true
    var action: () -> Void
    var body: some View {
        let theme = ThemePack.active
        Button(action: action) {
            Text(title)
                .bold()
                .frame(maxWidth: .infinity)
                .padding()
                .background(enabled ? theme.primary : theme.surface2)
                .foregroundColor(enabled ? .white : theme.textDim)
                .cornerRadius(12)
        }
        .disabled(!enabled)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
