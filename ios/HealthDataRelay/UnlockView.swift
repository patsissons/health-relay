import HealthDataRelayKit
import StoreKit
import SwiftUI

/// What Full adds, the trial, the three ways to pay, and the terms
/// subscriptions must show (guideline 3.1.2).
struct UnlockView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var store: Store { model.store }

    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyURL = URL(string: "https://health-data-relay.lgtm.page/privacy/")!

    var body: some View {
        NavigationStack {
            List {
                Section {
                    feature("Pipelines run by themselves", "When Health changes, on a schedule or at a time, in the background.", "clock.arrow.circlepath")
                    feature("Shortcuts and widgets", "Run pipelines from automations and the Home Screen.", "square.grid.2x2")
                    feature("AI tools and the Mac", "The MCP server for tools on your network, and the Mac dashboard.", "dot.radiowaves.left.and.right")
                    feature("Your own templates", "Write, import and edit templates in any format.", "doc.text")
                } header: {
                    Text("Health Data Relay Full")
                } footer: {
                    Text("Free keeps running pipelines when you tap Run, Export, and Charts.")
                }

                Section {
                    LabeledContent("Now", value: store.statusText())
                        .accessibilityIdentifier("unlock-status")
                    if !store.trialUsed, store.access.isFree {
                        buy(Store.trialID, title: "Try everything free for 7 days", detail: "No charge, and nothing renews. After 7 days, pipelines run when you tap Run until you choose a plan.", prominent: true)
                            .accessibilityIdentifier("start-trial")
                    }
                }

                if !isFull {
                    Section {
                        buy(Store.monthlyID, title: "Monthly", detail: "Renews each month.", prominent: false)
                            .accessibilityIdentifier("buy-monthly")
                        buy(Store.yearlyID, title: "Yearly", detail: "Renews each year.", prominent: false)
                            .accessibilityIdentifier("buy-yearly")
                        buy(Store.lifetimeID, title: "Lifetime", detail: "Pay once. Yours to keep.", prominent: false)
                            .accessibilityIdentifier("buy-lifetime")
                    } header: {
                        Text("Choose a plan")
                    } footer: {
                        Text("Monthly and Yearly renew automatically until cancelled at least 24 hours before the period ends, and are charged to your Apple Account. Manage or cancel them in Settings › your name › Subscriptions.")
                    }
                }

                Section {
                    Button("Restore purchases") { Task { await store.restore() } }
                        .disabled(store.busy)
                    Link("Terms of Use", destination: Self.termsURL)
                    Link("Privacy Policy", destination: Self.privacyURL)
                }
            }
            .navigationTitle("Unlock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("unlock-done")
                }
            }
            .task { await store.loadProducts() }
            .alert("Purchases", isPresented: Binding { store.message != nil } set: { if !$0 { store.message = nil } }) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(store.message ?? "")
            }
        }
    }

    private var isFull: Bool {
        if case .full = store.access { return true }
        return false
    }

    private func feature(_ title: String, _ detail: String, _ symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol)
        }
    }

    @ViewBuilder
    private func buy(_ id: String, title: String, detail: String, prominent: Bool) -> some View {
        let product = store.products[id]
        Button {
            Task {
                if await store.purchase(id), !store.access.isFree { dismiss() }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(prominent ? .headline : .body)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let product {
                    Text(price(product)).font(.body.monospacedDigit())
                } else if store.loadingProducts {
                    ProgressView()
                } else {
                    Text("Unavailable").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(product == nil || store.busy)
    }

    private func price(_ product: Product) -> String {
        if product.price == 0 { return "Free" }
        switch product.subscription?.subscriptionPeriod.unit {
        case .month: return "\(product.displayPrice)/month"
        case .year: return "\(product.displayPrice)/year"
        default: return product.displayPrice
        }
    }
}

/// On the Pipelines screen: the offer of a trial, or how long is left.
struct AccessNotice: View {
    @Environment(AppModel.self) private var model
    @AppStorage("trialOfferDismissed") private var dismissed = false
    @State private var unlocking = false

    var body: some View {
        Group {
            switch model.store.access {
            case .trial:
                Button {
                    unlocking = true
                } label: {
                    Label("Trial: \(Store.days(model.store.access.trialDaysLeft(now: .now) ?? 0)) left. Choose a plan", systemImage: "hourglass")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("trial-status")
            case .free where !dismissed:
                VStack(alignment: .leading, spacing: 8) {
                    Label(model.store.trialUsed ? "Your trial has ended" : "Try everything free for 7 days", systemImage: "sparkles")
                        .font(.headline)
                    Text(model.store.trialUsed
                         ? "Pipelines still run when you tap Run. Unlock Full to run them by themselves again."
                         : "Run pipelines by themselves, from Shortcuts and widgets, serve AI tools, and write your own templates.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(model.store.trialUsed ? "See plans" : "Start free trial") { unlocking = true }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("offer-unlock")
                        Button("Not now") { dismissed = true }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
            default:
                EmptyView()
            }
        }
        .sheet(isPresented: $unlocking) { UnlockView() }
    }
}
