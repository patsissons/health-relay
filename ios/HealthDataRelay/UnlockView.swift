import HealthDataRelayKit
import StoreKit
import SwiftUI

/// What Full adds, how long the trial has left, the three ways to pay, and
/// the terms subscriptions must show (guideline 3.1.2).
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
                    feature("Pipelines", "Run them with a tap, when Health changes, on a schedule or at a time, in the background.", "clock.arrow.circlepath")
                    feature("All your history", "Export, send and chart as far back as Health goes, not only the last 7 days.", "calendar")
                    feature("Shortcuts and widgets", "Run pipelines from automations and the Home Screen.", "square.grid.2x2")
                    feature("AI tools and the Mac", "The MCP server for tools on your network, and the Mac dashboard.", "dot.radiowaves.left.and.right")
                    feature("Your own templates", "Write, import and edit templates in any format.", "doc.text")
                } header: {
                    Text("Health Data Relay Full")
                } footer: {
                    Text("Free keeps Export and Charts for the last 7 days.")
                }

                Section {
                    LabeledContent("Now", value: store.statusText())
                        .accessibilityIdentifier("unlock-status")
                } footer: {
                    if case .trial(let end) = store.access {
                        Text("Free until \(end.formatted(date: .abbreviated, time: .shortened)), with nothing to cancel. The trial reaches back 7 days. After it, pipelines stop running until you choose a plan; Export and Charts stay.")
                    }
                }

                if !isFull {
                    Section {
                        buy(Store.monthlyID, title: "Monthly", detail: "Renews each month.")
                            .accessibilityIdentifier("buy-monthly")
                        buy(Store.yearlyID, title: "Yearly", detail: "Renews each year.")
                            .accessibilityIdentifier("buy-yearly")
                        buy(Store.lifetimeID, title: "Lifetime", detail: "Pay once. Yours to keep.")
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
    private func buy(_ id: String, title: String, detail: String) -> some View {
        let product = store.products[id]
        Button {
            Task {
                if await store.purchase(id), !store.access.isFree { dismiss() }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
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
        switch product.subscription?.subscriptionPeriod.unit {
        case .month: return "\(product.displayPrice)/month"
        case .year: return "\(product.displayPrice)/year"
        default: return product.displayPrice
        }
    }
}

/// On the Pipelines screen. A first launch says what the trial is, how long
/// it lasts, what it leaves out, what stops and what it costs after (guideline 3.1.1); once
/// read, a small line counts down. When it ends, a card offers the plans.
struct AccessNotice: View {
    @Environment(AppModel.self) private var model
    @AppStorage("trialNoticeRead") private var trialRead = false
    @AppStorage("trialEndedDismissed") private var endedDismissed = false
    @State private var unlocking = false

    private var store: Store { model.store }

    var body: some View {
        Group {
            switch store.access {
            case .trial where !trialRead:
                card("Everything is free for \(Store.days(store.access.trialDaysLeft(now: .now) ?? 0))",
                     "Pipelines run by themselves, from Shortcuts and widgets, serve AI tools, and use your own templates, with the last 7 days of your data. Nothing to buy or cancel. After the trial, pipelines stop running and Export and Charts stay, unless you choose a plan\(fromPrice). A plan also reaches all your history.",
                     symbol: "sparkles", primary: "See plans", secondary: "Got it") { trialRead = true }
            case .trial:
                Button {
                    unlocking = true
                } label: {
                    Label("Trial: \(Store.days(store.access.trialDaysLeft(now: .now) ?? 0)) left. Choose a plan", systemImage: "hourglass")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("trial-status")
            case .free where !endedDismissed:
                card("Your trial has ended",
                     "Export and Charts still work for the last 7 days. Choose a plan to run pipelines again and reach all your history\(fromPrice).",
                     symbol: "hourglass.bottomhalf.filled", primary: "See plans", secondary: "Not now") { endedDismissed = true }
            default:
                EmptyView()
            }
        }
        .sheet(isPresented: $unlocking) { UnlockView() }
        .task { await store.loadProducts() }
    }

    /// ", from $0.99 a month", once StoreKit has the price.
    private var fromPrice: String {
        guard let monthly = store.products[Store.monthlyID] else { return "" }
        return ", from \(monthly.displayPrice) a month"
    }

    private func card(_ title: String, _ detail: String, symbol: String, primary: String, secondary: String, dismiss: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Button(primary) { unlocking = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("offer-unlock")
                Button(secondary, action: dismiss)
                    .accessibilityIdentifier("dismiss-notice")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }
}
