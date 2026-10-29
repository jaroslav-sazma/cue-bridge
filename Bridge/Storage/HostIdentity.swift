import Foundation
import IOKit

nonisolated enum HostIdentity {
    static func hardwareUUID() -> String? {
        let expert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard expert != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(expert) }
        let value = IORegistryEntryCreateCFProperty(expert, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
        guard let uuid = value?.takeRetainedValue() as? String, !uuid.isEmpty else { return nil }
        return uuid
    }
}
