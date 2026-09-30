import Foundation
import Combine
import StoreKit

/// StoreKit 2 purchases for Emberfall Kingdom. Everything goes through Apple —
/// no external billing, no web links.
///
/// Products (must match App Store Connect exactly):
/// - app.emberfall.game.removeads ....... non-consumable $4.99 — Remove Ads
/// - app.emberfall.game.bundle.speedup .. consumable    $1.99 — 3× 15-min speedups
/// - app.emberfall.game.summon.epic10 .. consumable    $4.99 — 10× commander summon
///
/// Consumables: after a VERIFIED purchase the transaction id is handed to
/// GameState.grantConsumable, which grants locally (offline) or attaches the
/// id to the next server call for server-side receipt verification (online).
///
/// Concurrency: deliberately NOT @MainActor (mirrors the sibling games).
/// @Published mutations hop to the main actor explicitly; reads (e.g. from
/// AdsManager) are plain and main-thread in practice.
final class StoreManager: ObservableObject {
    static let shared = StoreManager()

    static let removeAdsID = "app.emberfall.game.removeads"
    static let speedupBundleID = "app.emberfall.game.bundle.speedup"
    static let summonEpic10ID = "app.emberfall.game.summon.epic10"

    static let allProductIDs = [removeAdsID, speedupBundleID, summonEpic10ID]

    @Published private(set) var removeAds = false
    @Published private(set) var products: [Product] = []
    @Published var purchaseInProgress = false
    @Published var lastError: String?

    /// Set after a verified consumable purchase (on the main actor);
    /// consumed by the next server-bound grant call.
    var lastTransactionId: String?

    private var updateListener: Task<Void, Error>?

    private enum Keys {
        static let removeAds = "emberfall.store.removeAds"
        static let grantedTransactions = "emberfall.store.grantedTxns"
    }

    /// Transaction ids already granted — an unfinished consumable transaction
    /// can be re-delivered by Transaction.updates after a crash; this keeps
    /// each purchase granting exactly once.
    private var grantedTransactions: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Keys.grantedTransactions) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Keys.grantedTransactions) }
    }

    private init() {
        removeAds = UserDefaults.standard.bool(forKey: Keys.removeAds)
        updateListener = Task.detached { [weak self] in
            for await result in Transaction.updates {
                await self?.handleUpdate(result)
            }
        }
        Task { await refreshEntitlements() }
    }

    // MARK: - Products

    func requestProducts() async {
        do {
            let fetched = try await Product.products(for: Self.allProductIDs)
            await MainActor.run { self.products = fetched }
        } catch {
            await MainActor.run {
                self.lastError = "Couldn't load store products. Check your connection and try again."
            }
        }
    }

    func product(for id: String) -> Product? {
        products.first { $0.id == id }
    }

    // MARK: - Purchase

    func purchase(_ product: Product) async {
        let busy = await MainActor.run { () -> Bool in
            guard !self.purchaseInProgress else { return true }
            self.purchaseInProgress = true
            return false
        }
        guard !busy else { return }
        defer { Task { await MainActor.run { self.purchaseInProgress = false } } }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                try await handleVerified(verification)
                await MainActor.run { self.lastError = nil }
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            await MainActor.run { self.lastError = "Purchase failed. Please try again." }
        }
    }

    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            await MainActor.run {
                self.lastError = "Couldn't reach the App Store. Check your connection and try again."
            }
        }
    }

    // MARK: - Verification & entitlements

    private func handleUpdate(_ result: VerificationResult<Transaction>) async {
        do { try await handleVerified(result) } catch { /* unverified: never grant */ }
    }

    private func handleVerified(_ verification: VerificationResult<Transaction>) async throws {
        switch verification {
        case .verified(let transaction):
            await MainActor.run { self.apply(transaction) }
            await transaction.finish()
        case .unverified:
            throw StoreError.failedVerification
        }
    }

    @MainActor
    private func apply(_ transaction: Transaction) {
        let txnId = String(transaction.id)
        switch transaction.productID {
        case Self.removeAdsID:
            removeAds = true
            UserDefaults.standard.set(true, forKey: Keys.removeAds)
        case Self.speedupBundleID, Self.summonEpic10ID:
            // Consumable: grant once per verified transaction.
            var granted = grantedTransactions
            if !granted.contains(txnId) {
                granted.insert(txnId)
                grantedTransactions = granted
                GameState.shared.grantConsumable(
                    transaction.productID,
                    transactionId: txnId)
            }
        default:
            break
        }
    }

    /// Re-reads current entitlements (covers restores and refunds).
    /// A revoked Remove Ads (refund) brings ads back.
    func refreshEntitlements() async {
        var entitledRemoveAds = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.revocationDate == nil,
               transaction.productID == Self.removeAdsID {
                entitledRemoveAds = true
            }
        }
        await MainActor.run {
            self.removeAds = entitledRemoveAds
            UserDefaults.standard.set(entitledRemoveAds, forKey: Keys.removeAds)
        }
    }
}

enum StoreError: Error {
    case failedVerification
}
