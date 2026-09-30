import SwiftUI

@main
struct EmberfallApp: App {
    @StateObject private var game = GameState.shared

    init() {
        // Ads SDK warms up at launch; loads retry silently in background.
        AdsManager.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(game)
                .preferredColorScheme(.dark)
                .task {
                    await StoreManager.shared.requestProducts()
                    await game.tryRestoreSession()
                }
        }
    }
}
