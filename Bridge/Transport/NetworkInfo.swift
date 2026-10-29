import Foundation

nonisolated enum NetworkInfo {
    static var instanceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }
}
