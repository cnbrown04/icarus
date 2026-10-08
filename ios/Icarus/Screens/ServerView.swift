import SwiftUI
import SyncKit

/// Pairs the phone with a server, from a typed address and code or from a pairing link (PLAN.md 14 row 6).
/// Onboarding shows it with Skip. Settings uses it for Pair and Re-pair.
struct ServerView: View {
    let sync: SyncController
    /// Onboarding passes an action that moves on. Otherwise a successful pairing pops the screen.
    var onFinish: (() -> Void)?
    /// Onboarding only. Continues without a server.
    var onSkip: (() -> Void)?
    /// Filled from `icarus://pair` when the phone opens the link.
    var link: PairingLink?

    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var code = ""
    @State private var failure: PairingFailure?
    @State private var isPairing = false

    var body: some View {
        Form {
            Section {
                TextField("Server address", text: $address)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("server.address")
                TextField("Pairing code", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("server.code")
            } footer: {
                Text(footerText)
            }

            if let onSkip {
                Section {
                    Button("Skip for now", action: onSkip)
                        .accessibilityIdentifier("server.skip")
                } footer: {
                    Text("Without a server, data stays on this iPhone.")
                }
            }
        }
        .navigationTitle("Server")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Pair", action: pair)
                    .disabled(isPairing || PairingCode.normalized(code) == nil || ServerURL.parse(address) == nil)
                    .accessibilityIdentifier("server.pair")
            }
        }
        .onAppear(perform: applyLink)
    }

    private var footerText: String {
        if let failure { return failure.message }
        return "Scan the QR code on the website with the Camera app to fill these in. Codes expire after 10 min."
    }

    private func applyLink() {
        guard let link else { return }
        if let serverURL = link.serverURL {
            address = serverURL.absoluteString
        }
        if let linkCode = link.code {
            code = linkCode
        }
    }

    private func pair() {
        guard let server = ServerURL.parse(address) else {
            failure = .address
            return
        }
        guard let normalized = PairingCode.normalized(code) else {
            failure = .code
            return
        }
        failure = nil
        isPairing = true
        Task {
            do {
                try await sync.pair(server: server, code: normalized)
                if let onFinish {
                    onFinish()
                } else {
                    dismiss()
                }
            } catch let error as PairingFailure {
                failure = error
            } catch {
                failure = .unreachable
            }
            isPairing = false
        }
    }
}
