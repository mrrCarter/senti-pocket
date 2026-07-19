import Foundation

#if canImport(Darwin)
import Darwin
#endif

enum DeviceRuntimeSnapshot {
    static var deviceModel: String {
        #if canImport(Darwin)
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return "unknown" }
        let machineSize = MemoryLayout.size(ofValue: systemInfo.machine)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: machineSize) {
                String(cString: $0)
            }
        }
        #else
        return "unsupported-host"
        #endif
    }

    static var operatingSystem: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    static var thermalLevel: ThermalLevel {
        #if os(iOS) || os(macOS)
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .unavailable
        }
        #else
        return .unavailable
        #endif
    }

    static var residentMemoryBytes: UInt64? {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
        #else
        return nil
        #endif
    }
}

extension Duration {
    var pocketMilliseconds: Double {
        let values = components
        return (Double(values.seconds) * 1_000) + (Double(values.attoseconds) / 1_000_000_000_000_000)
    }
}
