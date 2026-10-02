import Foundation
import Combine
import StoreKit

/// StoreKit 2 purchases for Emberfall Kingdom. Everything goes through Apple —
/// no external billing, no web links.
///
/// The game is fully ad-free, so there is deliberately no "Remove Ads"
/// product (a non-functional remove-ads IAP in an ad-free game risks an
/// Apple rejection).
///
/// Products (must match App Store Connect exactly):
/// - app.emberfall.game.bundle.speedup . consumable $1.99 — 3× 15-min speedups
/// - app.emberfall.game.summon.epic10 .. consumable $4.99 — 10× commander summon
/// - app.emberfall.game.bundle.warden .. consumable $4.99 — Warden's Cache:
///   8× 15-min speedups + 3 guaranteed epic summons
///
/// Consumables: after a VERIFIED purchase the transaction id is handed to
/// GameState.grantConsumable for a local grant. Online receipt fulfillment
/// is not implemented; checkout stays disabled until durable delivery is tested.
///
/// Concurrency: deliberately NOT @MainActor (mirrors the sibling games).
/// @Published mutations hop to the main actor explicitly.
final class StoreManager: ObservableObject {
    static let shared = StoreManager()

    // Keep checkout off until durable fulfillment, account binding and replay
    // handling pass sandbox tests. The supplied online receipt route is absent.
    static let purchasesEnabled = false

    static let speedupBundleID = "app.emberfall.game.bundle.speedup"
    static let summonEpic10ID = "app.emberfall.game.summon.epic10"
    static let wardenBundleID = "app.emberfall.game.bundle.warden"

    static let allProductIDs = [speedupBundleID, summonEpic10ID, wardenBundleID]

    @Published private(set) var products: [Product] = []
    @Published var purchaseInProgress = false
    @Published var lastError: String?

    /// Set after a verified consumable purchase (on the main actor);
    /// reserved for a future server grant integration (currently not transmitted).
    var lastTransactionId: String?

    private var updateListener: Task<Void, Error>?

    private enum Keys {
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
        updateListener = Task.detached { [weak self] in
            for await result in Transaction.updates {
                await self?.handleUpdate(result)
            }
        }
        Task { await refreshEntitlements() }
    }

    // MARK: - Products

    func requestProducts() async {
        guard Self.purchasesEnabled else { return }
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
        guard Self.purchasesEnabled else {
            await MainActor.run { self.lastError = "Purchases aren't available yet. You can keep playing for free." }
            return
        }
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
        // Leave any delivered transaction unfinished for a future verified
        // fulfillment path; do not acknowledge a purchase without granting it.
        guard Self.purchasesEnabled else { throw StoreError.purchasesUnavailable }
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
        case Self.speedupBundleID, Self.summonEpic10ID, Self.wardenBundleID:
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

    /// All products are consumables, so there are no persistent entitlements
    /// to refresh (restores are a no-op by design — kept for API symmetry).
    func refreshEntitlements() async {}
}

enum StoreError: Error {
    case failedVerification
    case purchasesUnavailable
}
