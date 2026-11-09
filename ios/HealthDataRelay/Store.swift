import Foundation
import HealthDataRelayKit
import Observation
import StoreKit

/// What the user bought, from StoreKit. Free: everything by hand. The $0
/// "7-day Trial" (guideline 3.1.1) and the three paid products unlock what
/// runs by itself. The answer is cached so a background launch can decide
/// before StoreKit replies.
@MainActor @Observable
final class Store {
    static let trialID = "com.patsissons.healthdatarelay.trial7"
    static let lifetimeID = "com.patsissons.healthdatarelay.lifetime"
    static let monthlyID = "com.patsissons.healthdatarelay.monthly"
    static let yearlyID = "com.patsissons.healthdatarelay.yearly"
    static let paidIDs = [monthlyID, yearlyID, lifetimeID]

    private(set) var access: Access
    /// Whether this Apple ID has started the trial, ended or not.
    private(set) var trialUsed = false
    private(set) var products: [String: Product] = [:]
    private(set) var loadingProducts = false
    private(set) var busy = false
    var message: String?
    /// Called on the main actor whenever `access` changes.
    var onChange: ((Access) -> Void)?

    /// DEBUG only: `-access free|trial|full` fixes the answer for UI tests.
    private let override: Access?
    private var updates: Task<Void, Never>?

    private static let cacheKey = "access"
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: "group.com.patsissons.healthdatarelay") ?? .standard
    }

    init() {
        if ProcessInfo.processInfo.arguments.contains("-reset") {
            Store.defaults.removeObject(forKey: Store.cacheKey)
            Store.defaults.removeObject(forKey: "trialUsed")
        }
        override = Store.launchOverride()
        access = override ?? Store.cached ?? .free
        trialUsed = Store.defaults.bool(forKey: "trialUsed")
    }

    /// The last answer StoreKit gave, for a launch that can't wait for it.
    /// A trial past its end is free, even if StoreKit hasn't said so yet.
    static var cached: Access? {
        guard let data = defaults.data(forKey: cacheKey), let access = try? JSONDecoder().decode(Access.self, from: data) else { return nil }
        if case .trial(let end) = access, end <= .now { return .free }
        return access
    }

    private static func launchOverride() -> Access? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-access"), i + 1 < args.count else { return nil }
        switch args[i + 1] {
        case "free": return .free
        case "trial": return .trial(endsAt: Date().addingTimeInterval(Access.trialLength))
        case "full": return .full(.lifetime)
        default: return nil
        }
        #else
        return nil
        #endif
    }

    /// Listens for purchases made elsewhere (another device, Ask to Buy,
    /// a renewal) and reads what is owned now.
    func start() {
        guard updates == nil else { return }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
                await self?.refresh()
            }
        }
        Task {
            await loadProducts()
            await refresh()
        }
    }

    func loadProducts() async {
        guard products.count < 4, !loadingProducts else { return }
        loadingProducts = true
        defer { loadingProducts = false }
        if let found = try? await Product.products(for: [Store.trialID] + Store.paidIDs) {
            products = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
        }
    }

    /// Reads current entitlements. A revoked or refunded purchase is gone.
    func refresh() async {
        var lifetime = false
        var subscription: Access.Plan?
        var trialStart: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result, t.revocationDate == nil else { continue }
            switch t.productID {
            case Store.lifetimeID: lifetime = true
            case Store.yearlyID: subscription = .yearly
            case Store.monthlyID: if subscription == nil { subscription = .monthly }
            case Store.trialID: trialStart = t.purchaseDate
            default: break
            }
        }
        trialUsed = trialStart != nil
        Store.defaults.set(trialUsed, forKey: "trialUsed")
        set(Access.resolve(lifetime: lifetime, subscription: subscription, trialStartedAt: trialStart, now: .now))
    }

    /// Re-checks a trial against the clock, so one ending while the app is
    /// open locks without waiting for StoreKit.
    func recheckClock() {
        if case .trial(let end) = access, end <= .now { set(.free) }
    }

    private func set(_ new: Access) {
        let value = override ?? new
        if let data = try? JSONEncoder().encode(value) { Store.defaults.set(data, forKey: Store.cacheKey) }
        guard value != access else { return }
        access = value
        onChange?(value)
    }

    /// Buys or starts the trial. False if cancelled, pending or failed.
    @discardableResult
    func purchase(_ id: String) async -> Bool {
        guard let product = products[id] else {
            message = "The App Store didn't answer. Check your connection and try again."
            return false
        }
        busy = true
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result else {
                    message = "The App Store couldn't verify that purchase."
                    return false
                }
                await transaction.finish()
                await refresh()
                return true
            case .pending:
                message = "Waiting for approval. It unlocks once it's approved."
                return false
            case .userCancelled:
                return false
            @unknown default:
                return false
            }
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    /// Asks the App Store for this Apple ID's purchases again.
    func restore() async {
        busy = true
        defer { busy = false }
        do {
            try await AppStore.sync()
            await refresh()
            if access.isFree { message = "Nothing to restore for this Apple ID." }
        } catch StoreKitError.userCancelled {
        } catch {
            message = error.localizedDescription
        }
    }

    /// "Free", "Trial: 3 days left", "Yearly".
    func statusText(now: Date = .now) -> String {
        switch access {
        case .free: trialUsed ? "Free (trial ended)" : "Free"
        case .trial: "Trial: \(Self.days(access.trialDaysLeft(now: now) ?? 0)) left"
        case .full(.monthly): "Monthly"
        case .full(.yearly): "Yearly"
        case .full(.lifetime): "Lifetime"
        }
    }

    static func days(_ n: Int) -> String { n == 1 ? "1 day" : "\(n) days" }
}
