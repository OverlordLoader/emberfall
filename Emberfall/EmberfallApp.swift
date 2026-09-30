import SwiftUI

@main
struct EmberfallApp: App {
    @StateObject private var game = GameState.shared

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
