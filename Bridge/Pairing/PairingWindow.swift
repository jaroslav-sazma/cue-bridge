import SwiftUI

struct PairingWindow: View {
    static let id = "pairing"

    let bridge: BridgeController
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 16) {
            content
        }
        .padding(24)
        .frame(width: 380)
        .onAppear { bridge.pairingWindowAppeared() }
        .onDisappear { bridge.pairingWindowDisappeared() }
    }

    @ViewBuilder private var content: some View {
        switch bridge.status.pairing {
        // Idle only until the start the window's appearance asked for is published.
        case .idle, .preparing:
            ProgressView("Getting ready to pair…")
        case .waiting(let expiresAt):
            WaitingView(expiresAt: expiresAt, port: listenerPort)
            Button("Cancel") { dismissWindow(id: Self.id) }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
        case .verifying:
            ProgressView("Connecting to the phone…")
            Button("Cancel") { dismissWindow(id: Self.id) }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
        case .enteringCode(let rejected):
            CodeEntryView(rejected: rejected) { bridge.enterCode($0) }
            Button("Cancel") { dismissWindow(id: Self.id) }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
        case .codeAccepted:
            ProgressView("Finishing pairing…")
            Button("Cancel") { dismissWindow(id: Self.id) }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
        case .committed:
            Label("Paired", systemImage: "checkmark.circle.fill")
                .font(.title2)
            if let prefix = bridge.status.peerFingerprintPrefix {
                Text("Phone \(prefix)").foregroundStyle(.secondary)
            }
            if let prefix = bridge.status.macFingerprintPrefix {
                Text("This Mac's certificate: \(prefix)").foregroundStyle(.secondary)
            }
            Button("Done") { dismissWindow(id: Self.id) }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        case .aborted(let reason), .failed(let reason):
            Label("Pairing ended", systemImage: "xmark.circle")
                .font(.title2)
            Text(reason)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack {
                Button("Close") { dismissWindow(id: Self.id) }
                Button("Try Again") { bridge.startPairing() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
    }

    private var listenerPort: UInt16? {
        if case .ready(let port) = bridge.status.listener { port } else { nil }
    }
}

private struct WaitingView: View {
    let expiresAt: Date
    let port: UInt16?

    var body: some View {
        Text("On your phone, open Launcher settings → Scenarios → ⋮ → Mac bridge in Cue: and tap Find Mac. Keep the phone on the same Wi-Fi network as this Mac.")
            .multilineTextAlignment(.center)
        HStack(spacing: 4) {
            Text("Waiting for the phone, ends in")
            Text(timerInterval: Date.now...max(expiresAt, .now), countsDown: true)
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
        #if DEBUG
        if let port {
            Text("Listening on port \(String(port)) (debug builds)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        #endif
    }
}

// The Mac's user types what the phone shows; the comparison is the Mac's, so a phone that is not the
// user's own, racing to pair at the same moment, shows a code that is not accepted here.
private struct CodeEntryView: View {
    static let digits = 6

    let rejected: Int
    let submit: (String) -> Void
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        Text("Type the code your phone shows:")
        TextField("000 000", text: $code)
            .font(.system(.largeTitle, design: .monospaced, weight: .semibold))
            .multilineTextAlignment(.center)
            .textFieldStyle(.roundedBorder)
            .frame(width: 200)
            .focused($focused)
            .onChange(of: code) { _, typed in
                let filtered = String(typed.filter(\.isASCIIDigit).prefix(Self.digits))
                if filtered != typed { code = filtered }
            }
            .onSubmit(enter)
            .onAppear { focused = true }
            .onChange(of: rejected) {
                code = ""
                focused = true
            }
        if rejected > 0 {
            Text("That is not the code on the phone. Check the digits and type them again.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.red)
        }
        Button("Pair", action: enter)
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .disabled(code.count != Self.digits)
    }

    private func enter() {
        guard code.count == Self.digits else { return }
        submit(code)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
