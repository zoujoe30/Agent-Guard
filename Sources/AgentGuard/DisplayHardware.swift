import CoreGraphics
import Darwin
import Foundation

enum DisplayBootSession {
    static func current() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }
}

struct ManagedDisplay: Codable, Equatable {
    let id: UInt32
    let uuid: String
    var vendor: UInt32? = nil
    var model: UInt32? = nil
    var serial: UInt32? = nil
    var bootSession: String? = nil
    func matchesOfflineSlot(id: UInt32, online: Bool, vendor: UInt32, model: UInt32, serial: UInt32, boot: String?) -> Bool {
        !online && id == self.id && self.vendor != nil && self.vendor != 0 && self.model != nil && self.model != 0
            && self.vendor == vendor && self.model == model && self.serial == serial
            && bootSession != nil && bootSession == boot
    }
}
struct DisplayRecoveryRecord: Codable {
    let token: UUID
    let ownerPID: Int32
    let builtIn: ManagedDisplay
    let brightness: Float
    let external: [ManagedDisplay]
}
enum DisplayExclusionPolicy {
    static let defaultsKey = "com.local.agentguard.excluded-display-uuids"
    static func configuredUUIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
    }
    static func excludes(_ uuid: String, in excluded: Set<String>) -> Bool {
        guard let identity = UUID(uuidString: uuid), identity != UUID(uuidString: "00000000-0000-0000-0000-000000000000") else { return false }
        return excluded.contains { UUID(uuidString: $0) == identity }
    }
    static func managed(_ displays: [ManagedDisplay], excluding excluded: Set<String>) -> [ManagedDisplay] {
        displays.filter { !excludes($0.uuid, in: excluded) }
    }
}
struct DisplayOperationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
protocol DisplayHardware {
    func capture() throws -> DisplayRecoveryRecord
    func brightness(_ display: ManagedDisplay, _ value: Float) throws
    func enable(_ display: ManagedDisplay, _ enabled: Bool) throws
    func blackoutHealth(_ record: DisplayRecoveryRecord) -> String?
}

/// No DDC, gamma, resolution changes, or window movement. The built-in desktop
/// stays online; macOS migrates/restores external windows on connect/disconnect.
@MainActor
final class NativeDisplayHardware: DisplayHardware {
    private let excludedUUIDs: () -> Set<String>
    init(excludedUUIDs: @escaping () -> Set<String> = { DisplayExclusionPolicy.configuredUUIDs() }) {
        self.excludedUUIDs = excludedUUIDs
    }
    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
    private typealias Toggle = @convention(c) (CGDisplayConfigRef, UInt32, Bool) -> CGError
    private typealias List = @convention(c) (UInt32, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>) -> CGError
    private typealias Info = @convention(c) (UInt32) -> Unmanaged<CFDictionary>?
    // Keep handles loaded for the lifetime of the process/function pointers.
    private let services = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private let core = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)

    private func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, _: T.Type) throws -> T {
        guard let handle, let address = dlsym(handle, name) else {
            throw DisplayOperationError(message: "当前 macOS 缺少显示控制接口：\(name)。")
        }
        return unsafeBitCast(address, to: T.self)
    }
    private func ids() throws -> [UInt32] {
        let list = try symbol(sky, "CGSGetDisplayList", List.self)
        var ids = [UInt32](repeating: 0, count: 64)
        var count: UInt32 = 0
        guard list(64, &ids, &count) == .success, count < 64 else {
            throw DisplayOperationError(message: "无法完整读取显示器列表。")
        }
        return Array(ids.prefix(Int(count)))
    }
    private func identity(_ id: UInt32) throws -> ManagedDisplay? {
        let info = try symbol(core, "CoreDisplay_DisplayCreateInfoDictionary", Info.self)
        guard let dictionary = info(id)?.takeRetainedValue() as? [String: Any],
              let uuid = dictionary["kCGDisplayUUID"] as? String else { return nil }
        return ManagedDisplay(id: id, uuid: uuid, vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id), bootSession: DisplayBootSession.current())
    }
    private func resolve(_ display: ManagedDisplay) throws -> UInt32 {
        let current = try ids()
        let matches = try current.filter { try identity($0)?.uuid == display.uuid }
        if matches.count == 1, let id = matches.first { return id }
        // CoreDisplay omits UUID for a software-disabled display on this Mac.
        // Recover only its still-enumerated ORIGINAL slot, never a same-model
        // replacement at a different id, and require all captured hardware fields.
        if matches.isEmpty, current.contains(display.id),
           display.matchesOfflineSlot(id: display.id, online: CGDisplayIsOnline(display.id) != 0,
                                      vendor: CGDisplayVendorNumber(display.id), model: CGDisplayModelNumber(display.id),
                                      serial: CGDisplaySerialNumber(display.id), boot: DisplayBootSession.current()) {
            return display.id
        }
        throw DisplayOperationError(message: "无法唯一定位显示器 \(display.uuid)，请重新连接后重试恢复。")
    }
    func capture() throws -> DisplayRecoveryRecord {
        _ = try symbol(sky, "CGSConfigureDisplayEnabled", Toggle.self)
        _ = try symbol(services, "DisplayServicesSetBrightness", SetBrightness.self)
        let all = try ids().filter { CGDisplayIsOnline($0) != 0 }
        guard let id = all.first(where: { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsActive($0) != 0 }),
              let builtIn = try identity(id) else {
            throw DisplayOperationError(message: "托管黑屏需要保持 Mac 内屏在线，请打开屏幕上盖。")
        }
        let get = try symbol(services, "DisplayServicesGetBrightness", GetBrightness.self)
        var brightness: Float = 0
        let result = get(id, &brightness)
        guard result == 0, brightness.isFinite, brightness > 0, brightness <= 1 else {
            throw DisplayOperationError(message: "无法保存可见内屏亮度，请先调亮内屏。")
        }
        let excluded = excludedUUIDs()
        let external = try all.filter { CGDisplayIsBuiltin($0) == 0 }.compactMap { id -> ManagedDisplay? in
            guard let display = try identity(id) else {
                throw DisplayOperationError(message: "当前外屏身份不支持安全软断开。")
            }
            if DisplayExclusionPolicy.excludes(display.uuid, in: excluded) { return nil }
            guard CGDisplayIsInMirrorSet(id) == 0 else {
                throw DisplayOperationError(message: "当前外屏身份或镜像模式不支持安全软断开。")
            }
            return display
        }
        return DisplayRecoveryRecord(token: UUID(), ownerPID: getpid(), builtIn: builtIn, brightness: brightness, external: external)
    }
    func brightness(_ display: ManagedDisplay, _ value: Float) throws {
        let id = try resolve(display)
        guard CGDisplayIsBuiltin(id) != 0, CGDisplayIsOnline(id) != 0 else {
            throw DisplayOperationError(message: "内屏不可用，请打开屏幕上盖。")
        }
        let set = try symbol(services, "DisplayServicesSetBrightness", SetBrightness.self)
        let result = set(id, value)
        guard result == 0 else { throw DisplayOperationError(message: "内屏亮度恢复/设置失败：\(result)。") }
        let get = try symbol(services, "DisplayServicesGetBrightness", GetBrightness.self)
        var actual: Float = -1
        guard get(id, &actual) == 0, actual.isFinite, abs(actual - value) < 0.03 else {
            throw DisplayOperationError(message: "内屏亮度尚未通过回读核验，请重试恢复。")
        }
    }
    func enable(_ display: ManagedDisplay, _ enabled: Bool) throws {
        let id = try resolve(display)
        guard CGDisplayIsBuiltin(id) == 0 else { throw DisplayOperationError(message: "拒绝断开内屏。") }
        if (CGDisplayIsOnline(id) != 0) == enabled { return }
        let toggle = try symbol(sky, "CGSConfigureDisplayEnabled", Toggle.self)
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            throw DisplayOperationError(message: "无法开始显示配置。")
        }
        let result = toggle(config, id, enabled)
        guard result == .success else {
            CGCancelDisplayConfiguration(config)
            throw DisplayOperationError(message: "外屏\(enabled ? "重连" : "断开")失败：\(result.rawValue)。")
        }
        // App-scoped disconnection adds OS rollback if the main process dies.
        let completion = CGCompleteDisplayConfiguration(config, enabled ? .forSession : .forAppOnly)
        let detail = "id=\(id), UUID=\(display.uuid), online=\(CGDisplayIsOnline(id)), active=\(CGDisplayIsActive(id))"
        guard completion == .success else {
            let advice = enabled ? "电视/显示器可能已关机或断开，可开机后在菜单重试显示恢复；这不妨碍验证解除。" : "已停止进入黑屏并尝试回滚。"
            throw DisplayOperationError(message: "系统拒绝外屏\(enabled ? "重连" : "断开")配置（\(completion.rawValue)；\(detail)）。\(advice)")
        }
        guard (CGDisplayIsOnline(id) != 0) == enabled else {
            throw DisplayOperationError(message: "外屏配置已提交，但在线状态尚未核验（\(detail)），请稍后重试显示恢复。")
        }
    }
    func blackoutHealth(_ record: DisplayRecoveryRecord) -> String? {
        do {
            let all = try ids().filter { CGDisplayIsOnline($0) != 0 }
            let internalID = try resolve(record.builtIn)
            guard all.contains(internalID), CGDisplayIsActive(internalID) != 0 else { return "托管内屏已离线。" }
            let excluded = excludedUUIDs()
            let external = try all.filter { CGDisplayIsBuiltin($0) == 0 }.map { id in
                guard let display = try identity(id) else {
                    throw DisplayOperationError(message: "无法核验在线外屏身份，已停止黑屏以便恢复。")
                }
                return display
            }
            if !DisplayExclusionPolicy.managed(external, excluding: excluded).isEmpty {
                return "检测到外屏重新连接或新增外屏，已停止黑屏以便恢复。"
            }
            return nil
        } catch { return error.localizedDescription }
    }
}
