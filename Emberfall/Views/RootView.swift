import SwiftUI

/// Root: tab bar over the game, onboarding overlay for first launch,
/// "while you were away" sheet, and a gentle error banner.
struct RootView: View {
    @EnvironmentObject var game: GameState
    @State private var tab = 0

    var body: some View {
        let theme = ThemePack.active
        ZStack {
            theme.background.ignoresSafeArea()
            TabView(selection: $tab) {
                CityView().tabItem {
                    Label("City", systemImage: "crown.fill")
                }.tag(0)
                MapView().tabItem {
                    Label("Wilds", systemImage: "map.fill")
                }.tag(1)
                SummonView().tabItem {
                    Label("Wardens", systemImage: "sparkles")
                }.tag(2)
                QuestsView().tabItem {
                    Label("Quests", systemImage: "scroll.fill")
                }.tag(3)
                SettingsView().tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }.tag(4)
            }
            .tint(theme.primary)

            if !game.onboardingDone {
                OnboardingView()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .sheet(item: $game.awaySheet) { box in
            AwaySheet(values: box.values)
        }
        .overlay(alignment: .top) {
            if let err = game.lastError {
                ErrorBanner(text: err) { game.clearError() }
                    .padding(.top, 8)
                    .padding(.horizontal)
                    .zIndex(20)
            }
        }
    }
}

struct AwayGainsBox: Identifiable {
    let id: UUID
    let values: [(ResourceKind, Double)]
}

struct AwaySheet: View {
    let values: [(ResourceKind, Double)]
    @Environment(\.dismiss) var dismiss
    var body: some View {
        let theme = ThemePack.active
        VStack(spacing: 16) {
            Image(systemName: "moon.stars.fill")
                .font(.largeTitle).foregroundColor(theme.gold)
            Text(theme.away.title).font(.title2).bold().foregroundColor(theme.text)
            Text(theme.away.body).foregroundColor(theme.textDim)
            ForEach(values, id: \.0) { kind, amount in
                HStack {
                    Image(systemName: kind.icon).foregroundColor(theme.gold)
                    Text(kind.rawValue.capitalized).foregroundColor(theme.text)
                    Spacer()
                    Text("+\(Int(amount))").bold().foregroundColor(theme.success)
                }
                .padding(.horizontal, 32)
            }
            ThemedButton(title: "Welcome back") {
                GameState.shared.dismissAway()
                dismiss()
            }
            .padding(.horizontal, 32)
        }
        .padding()
        .presentationDetents([.medium])
    }
}

struct ErrorBanner: View {
    let text: String
    var onDismiss: () -> Void
    var body: some View {
        let theme = ThemePack.active
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(theme.gold)
            Text(text).font(.caption).foregroundColor(theme.text)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark").foregroundColor(theme.textDim)
            }
        }
        .padding(10)
        .background(theme.surface2)
        .cornerRadius(10)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { onDismiss() }
        }
    }
}
