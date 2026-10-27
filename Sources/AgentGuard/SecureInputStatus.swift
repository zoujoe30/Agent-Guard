import AppKit
import Carbon
import IOKit

struct SecureInputStatus {
    let enabled: Bool
    let ownerPID: Int32?
    let ownerName: String?

    static func current() -> SecureInputStatus {
        guard IsSecureEventInputEnabled() else {
            return SecureInputStatus(enabled: false, ownerPID: nil, ownerName: nil)
        }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        let users = IORegistryEntryCreateCFProperty(
            root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [[String: Any]]
        let session = users?.first { ($0["kCGSSessionOnConsoleKey"] as? Bool) == true }
        let pid = (session?["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value
        let app = pid.flatMap { $0 > 0 ? NSRunningApplication(processIdentifier: $0) : nil }
        return SecureInputStatus(enabled: true, ownerPID: pid, ownerName: app?.localizedName)
    }

    var blockingMessage: String {
        let owner = ownerName ?? ownerPID.map { "进程 \($0)" } ?? "未知进程"
        return "系统安全输入已开启（占用者：\(owner)），无法保证键盘拦截。请先在占用应用中结束安全输入，再重试。"
    }
}
