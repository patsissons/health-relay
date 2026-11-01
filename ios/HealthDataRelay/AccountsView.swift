import AuthenticationServices
import CryptoKit
import HealthDataRelayKit
import SwiftUI

/// Cloud accounts pipelines can save to.
struct AccountsView: View {
    @Environment(AppModel.self) private var model
    @State private var failure: String?

    var body: some View {
        List {
            Section {
                ForEach(model.accounts) { account in
                    LabeledContent(account.name, value: account.provider.title)
                }
                .onDelete { offsets in
                    let ids = offsets.map { model.accounts[$0].id }
                    Task { for id in ids { await model.disconnect(id) } }
                }
                if model.accounts.isEmpty { Text("None yet").foregroundStyle(.secondary) }
            } footer: {
                Text("Removing an account signs the app out. A pipeline using it will ask you to sign in again.")
            }
            Section {
                ForEach(ConnectedAccount.Provider.allCases, id: \.self) { provider in
                    if AppModel.oauth(provider) != nil {
                        Button("Connect \(provider.title)") {
                            Task {
                                do {
                                    try await model.connect(provider)
                                    failure = nil
                                } catch {
                                    failure = error.localizedDescription
                                }
                            }
                        }
                    } else {
                        LabeledContent(provider.title, value: "Not set up in this build")
                            .foregroundStyle(.secondary)
                    }
                }
                if let failure { Text(failure).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Connected accounts")
        .task { await model.reloadAccounts() }
    }
}

/// Signing in with OAuth and PKCE in Safari's secure sheet.
enum OAuthSignIn {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// A long random string and its hash, which prove this app asked.
    static func pkce() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        func url(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let verifier = url(Data(bytes))
        return (verifier, url(Data(SHA256.hash(data: Data(verifier.utf8)))))
    }

    @MainActor
    static func run(_ provider: OAuthProvider) async throws -> OAuthTokens {
        let (verifier, challenge) = pkce()
        let state = UUID().uuidString
        let answer: URL = try await withCheckedThrowingContinuation { c in
            let session = ASWebAuthenticationSession(url: provider.authorizeURL(challenge: challenge, state: state), callbackURLScheme: provider.redirectScheme) { url, error in
                if let url { c.resume(returning: url) } else { c.resume(throwing: error ?? Failure(errorDescription: "Sign-in didn't finish.")) }
            }
            session.presentationContextProvider = Anchor.shared
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
        let items = URLComponents(url: answer, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
        // Only this sign-in's answer counts.
        guard item("state") == state, let code = item("code") else {
            throw Failure(errorDescription: item("error_description") ?? item("error") ?? "Sign-in didn't finish.")
        }
        return try await provider.exchange(code: code, verifier: verifier)
    }

    @MainActor
    private final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        static let shared = Anchor()

        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}
