import Foundation

// The menu-bar icon's coarse state. The status it is drawn from changes with every Bluetooth frame;
// this changes only when what the icon shows does, so the label is not redrawn per frame.
nonisolated enum MenuBarState: Equatable, Sendable {
    case notPaired
    case idle
    case connected
    case problem

    // Bluetooth trouble counts only while paired: pairing itself is found over Bonjour, but a paired
    // phone cannot tell this Mac is nearby without the advertisement.
    init(paired: Bool, unusable: Bool, connected: Bool, storageError: Bool, bluetoothProblem: Bool) {
        self = if unusable || storageError || (paired && bluetoothProblem) {
            .problem
        } else if !paired {
            .notPaired
        } else if connected {
            .connected
        } else {
            .idle
        }
    }

    var symbol: String {
        switch self {
        case .notPaired: "iphone.slash"
        case .idle: "iphone"
        case .connected: "iphone.radiowaves.left.and.right"
        case .problem: "iphone.badge.exclamationmark"
        }
    }
}
