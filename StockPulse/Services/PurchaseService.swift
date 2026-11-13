import Foundation
import StoreKit

@MainActor
final class PurchaseService: ObservableObject {

    static let shared = PurchaseService()

    static let productID = "com.stockpulse.pro.unlimitedwatchlist"
    static let freeWatchlistLimit = 3

    @Published var isPremium: Bool = false
    @Published var product: Product?
    @Published var purchaseError: String?

    private init() {
        isPremium = UserDefaults.standard.bool(forKey: "isPremium")
        Task { await load() }
        listenForTransactions()
    }

    // MARK: - Load product

    func load() async {
        do {
            let products = try await Product.products(for: [Self.productID])
            product = products.first
        } catch {
            print("StoreKit product load failed: \(error)")
        }
        await checkEntitlement()
    }

    // MARK: - Purchase

    func purchase() async -> Bool {
        guard let product else {
            purchaseError = "Product not available. Check your internet connection."
            return false
        }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                isPremium = true
                UserDefaults.standard.set(true, forKey: "isPremium")
                Analytics.capture("iap_purchased", ["product": Self.productID])
                return true
            case .userCancelled:
                return false
            case .pending:
                purchaseError = "Purchase is pending approval."
                return false
            @unknown default:
                return false
            }
        } catch {
            purchaseError = "Purchase failed: \(error.localizedDescription)"
            Analytics.capture("iap_failed", ["error": error.localizedDescription])
            return false
        }
    }

    // MARK: - Restore

    func restore() async {
        do {
            try await AppStore.sync()
            await checkEntitlement()
            if isPremium {
                Analytics.capture("iap_restored")
            }
        } catch {
            purchaseError = "Restore failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Entitlement check

    func checkEntitlement() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let tx) = result, tx.productID == Self.productID {
                isPremium = true
                UserDefaults.standard.set(true, forKey: "isPremium")
                return
            }
        }
    }

    // MARK: - Background transaction listener

    private func listenForTransactions() {
        Task {
            for await result in Transaction.updates {
                if case .verified(let tx) = result, tx.productID == Self.productID {
                    await tx.finish()
                    isPremium = true
                    UserDefaults.standard.set(true, forKey: "isPremium")
                }
            }
        }
    }

    // MARK: - Helper

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified: throw StoreError.failedVerification
        case .verified(let value): return value
        }
    }

    var formattedPrice: String {
        product?.displayPrice ?? "$0.99"
    }
}

enum StoreError: Error {
    case failedVerification
}
