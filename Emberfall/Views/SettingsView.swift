import SwiftUI
import StoreKit

/// Settings: kingdom server connection, the shop (StoreKit 2 paywall),
/// shield stub (phase 2), sound, and debug tools.
struct SettingsView: View {
    @EnvironmentObject var game: GameState
    @ObservedObject var store = StoreManager.shared
    @State private var serverURL = UserDefaults.standard.string(forKey: "emberfall.serverURL") ?? ""
    @State private var showWorlds = false
    @State private var sound = UserDefaults.standard.bool(forKey: "emberfall.sound") != false
    @State private var coordinator: AppleSignInCoordinator?

    var body: some View {
        let theme = ThemePack.active
        NavigationStack {
            List {
                accountSection(theme)
                shopSection(theme)
                shieldSection(theme)
                prefsSection(theme)
                #if DEBUG
                debugSection(theme)
                #endif
                aboutSection(theme)
            }
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showWorlds) {
                WorldPickerView { showWorlds = false }
            }
        }
    }

    // MARK: - Account / server

    private func accountSection(_ theme: ThemePack) -> some View {
        Section {
            if game.mode == .online {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(theme.success)
                    VStack(alignment: .leading) {
                        Text("Connected").foregroundColor(theme.text)
                        Text(game.api.player?.displayName ?? "").font(.caption).foregroundColor(theme.textDim)
                    }
                    Spacer()
                    Button("Disconnect") { game.goOffline() }
                        .font(.caption).foregroundColor(theme.danger)
                }
            } else {
                TextField("Kingdom server (e.g. kingdom.example.com)", text: $serverURL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .onChange(of: serverURL) { _, v in
                        UserDefaults.standard.set(v, forKey: "emberfall.serverURL")
                    }
                Button(action: connectWithApple) {
                    HStack {
                        Image(systemName: "apple.logo")
                        Text("Connect with Apple")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(Color.white).foregroundColor(.black)
                    .cornerRadius(10)
                }
                .disabled(serverURL.trimmingCharacters(in: .whitespaces).isEmpty)
                Text("Enter Henry's server address first, then connect. Offline play needs nothing.")
                    .font(.caption).foregroundColor(theme.textDim)
            }
        } header: {
            Text("Kingdom server").foregroundColor(theme.textDim)
        }
        .listRowBackground(theme.surface)
    }

    private func connectWithApple() {
        let c = AppleSignInCoordinator()
        coordinator = c
        c.onToken = { token in
            Task {
                do {
                    try await game.api.signInWithApple(identityToken: token)
                    await game.loadWorlds()
                    showWorlds = true
                } catch {
                    game.lastError = (error as? APIError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
        c.onError = { msg in game.lastError = msg }
        c.start()
    }

    // MARK: - Shop (paywall)

    private func shopSection(_ theme: ThemePack) -> some View {
        Section {
            ForEach(store.products) { product in
                shopRow(product, theme)
            }
            if store.products.isEmpty {
                Text("Loading the shop…").font(.caption).foregroundColor(theme.textDim)
                    .onAppear { Task { await store.requestProducts() } }
            }
            Button("Restore purchases") {
                Task { await store.restorePurchases() }
            }
            .font(.caption)
            if let err = store.lastError {
                Text(err).font(.caption).foregroundColor(theme.danger)
            }
        } header: {
            Text("Shop — supports the hearth").foregroundColor(theme.textDim)
        } footer: {
            Text("Everything is playable free. Purchases are cosmetic or convenience — never pay-to-win, never required.")
                .foregroundColor(theme.textDim)
        }
        .listRowBackground(theme.surface)
    }

    private func shopRow(_ product: Product, _ theme: ThemePack) -> some View {
        // All products are consumables — no "Owned" state to track.
        HStack {
            VStack(alignment: .leading) {
                Text(product.displayName).foregroundColor(theme.text)
                Text(shopBlurb(product.id)).font(.caption).foregroundColor(theme.textDim)
            }
            Spacer()
            Button(product.displayPrice) {
                Task { await store.purchase(product) }
            }
            .font(.caption).bold()
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(theme.primary).foregroundColor(.white)
            .cornerRadius(8)
            .disabled(store.purchaseInProgress)
        }
    }

    private func shopBlurb(_ id: String) -> String {
        switch id {
        case StoreManager.speedupBundleID: return "3× 15-minute speedups for any queue."
        case StoreManager.summonEpic10ID: return "Summon 10 wardens at once."
        case StoreManager.wardenBundleID: return "Warden's Cache: 8× speedups + 3 epic wardens."
        default: return ""
        }
    }

    // MARK: - Shield (phase 2 stub — present but honest)

    private func shieldSection(_ theme: ThemePack) -> some View {
        Section {
            HStack {
                Image(systemName: "shield.fill").foregroundColor(theme.textDim)
                VStack(alignment: .leading) {
                    Text("City Shield").foregroundColor(theme.textDim)
                    Text(theme.shieldStub).font(.caption).foregroundColor(theme.textDim)
                }
            }
            .opacity(0.7)
        } header: {
            HStack { Text("Protection").foregroundColor(theme.textDim); Spacer(); Text("PHASE 2").font(.caption2).bold().foregroundColor(theme.accent) }
        }
        .listRowBackground(theme.surface)
    }

    // MARK: - Prefs

    private func prefsSection(_ theme: ThemePack) -> some View {
        Section {
            Toggle("Sound effects", isOn: $sound)
                .onChange(of: sound) { _, v in UserDefaults.standard.set(v, forKey: "emberfall.sound") }
            Button("Replay tutorial") {
                game.replayTutorial()
            }
        }
        .listRowBackground(theme.surface)
    }

    // MARK: - Debug (never in review builds)

    #if DEBUG
    private func debugSection(_ theme: ThemePack) -> some View {
        Section {
            Button("Dev sign-in (no Apple)") {
                let id = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
                Task {
                    do {
                        try await game.api.devSignIn(deviceId: id)
                        await game.loadWorlds()
                        showWorlds = true
                    } catch {
                        game.lastError = (error as? APIError)?.errorDescription ?? error.localizedDescription
                    }
                }
            }
            .disabled(serverURL.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Reset local save", role: .destructive) {
                game.local.resetAll()
                game.refreshLocal()
            }
            Text("Debug build — this section never ships to App Review.")
                .font(.caption).foregroundColor(theme.textDim)
        } header: {
            Text("Developer").foregroundColor(theme.textDim)
        }
        .listRowBackground(theme.surface)
    }
    #endif

    private func aboutSection(_ theme: ThemePack) -> some View {
        Section {
            HStack { Text("Version").foregroundColor(theme.textDim); Spacer(); Text("1.0").foregroundColor(theme.text) }
            HStack { Text("Theme").foregroundColor(theme.textDim); Spacer(); Text(theme.displayName).foregroundColor(theme.text) }
            HStack { Text("Mode").foregroundColor(theme.textDim); Spacer(); Text(game.mode == .online ? "Online" : "Offline").foregroundColor(theme.text) }
        } header: {
            Text("About").foregroundColor(theme.textDim)
        }
        .listRowBackground(theme.surface)
    }
}

// MARK: - World picker

struct WorldPickerView: View {
    @EnvironmentObject var game: GameState
    @Environment(\.dismiss) var dismiss
    var onDone: () -> Void

    var body: some View {
        let theme = ThemePack.active
        NavigationStack {
            List {
                if game.worlds.isEmpty {
                    Text("No open worlds found on this server.").foregroundColor(theme.textDim)
                }
                ForEach(game.worlds) { w in
                    Button(action: {
                        Task {
                            await game.joinWorld(w)
                            onDone()
                            dismiss()
                        }
                    }) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(w.name).foregroundColor(theme.text)
                                Text("\(w.players) wardens • \(w.status)")
                                    .font(.caption).foregroundColor(theme.textDim)
                            }
                            Spacer()
                            if w.status != "open" {
                                Text(w.status.uppercased()).font(.caption2).foregroundColor(theme.gold)
                            }
                        }
                    }
                    .disabled(w.status == "full" || w.status == "closed")
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle("Choose your world")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
