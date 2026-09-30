import SwiftUI

/// Fun in 60 seconds: three guided steps (build → march → summon), always
/// skip-able. Copy comes from the theme, never hardcoded here.
struct OnboardingView: View {
    @EnvironmentObject var game: GameState
    @State private var step = 0

    var body: some View {
        let theme = ThemePack.active
        ZStack {
            theme.background.opacity(0.97).ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer()
                stepArt(theme)
                Text(theme.tutorial.title)
                    .font(.largeTitle).bold()
                    .foregroundColor(theme.text)
                if let s = theme.tutorial.steps[safe: step] {
                    VStack(spacing: 8) {
                        Text("Step \(step + 1) of \(theme.tutorial.steps.count)")
                            .font(.caption).foregroundColor(theme.textDim)
                        Text(s.title).font(.title3).bold().foregroundColor(theme.text)
                        Text(s.body).foregroundColor(theme.textDim).multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 32)
                }
                Spacer()
                HStack(spacing: 12) {
                    Button("Skip") {
                        game.completeOnboarding()
                        Haptics.tap()
                    }
                    .foregroundColor(theme.textDim)
                    .padding()
                    ThemedButton(title: step < theme.tutorial.steps.count - 1 ? "Next" : "Begin") {
                        Haptics.tap()
                        if step < theme.tutorial.steps.count - 1 {
                            step += 1
                        } else {
                            game.completeOnboarding()
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
            }
        }
    }

    /// Illustration for the current tutorial step (farm → march → summon),
    /// from the theme's art. Falls back to the flame glyph.
    @ViewBuilder
    private func stepArt(_ theme: ThemePack) -> some View {
        let keys = ["farm", "march", "summon"]
        let key = step < keys.count ? keys[step] : "welcome"
        if let name = theme.onboardingArt(key), UIImage(named: name) != nil {
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(height: 190)
                .cornerRadius(18)
        } else {
            Image(systemName: "flame.fill")
                .font(.system(size: 64))
                .foregroundColor(theme.primary)
        }
    }
}
