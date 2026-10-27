import Foundation
import ObjectiveC
import Darwin

/// CoreBrightness is private: resolve and validate the ABI before calling it.
@MainActor
final class KeyboardBacklightHardware {
    private let client: NSObject
    init() throws {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
            throw Failure(message: "键盘背光接口不可用。")
        }
        client = type.init()
        for (name, encoding) in [
            ("copyKeyboardBacklightIDs", "@16@0:8"),
            ("brightnessForKeyboard:", "f24@0:8Q16"),
            ("isKeyboardBuiltIn:", "B24@0:8Q16"),
            ("isAutoBrightnessEnabledForKeyboard:", "B24@0:8Q16"),
            ("enableAutoBrightness:forKeyboard:", "B28@0:8B16Q20"),
            ("setBrightness:forKeyboard:", "B28@0:8f16Q20")
        ] {
            guard let method = class_getInstanceMethod(type, NSSelectorFromString(name)),
                  let actual = method_getTypeEncoding(method), String(cString: actual) == encoding else {
                throw Failure(message: "键盘背光接口签名不兼容。")
            }
        }
    }
    struct Failure: Error { let message: String }
    var ids: [UInt64] {
        let selector = NSSelectorFromString("copyKeyboardBacklightIDs")
        return (client.perform(selector)?.takeRetainedValue() as? [NSNumber] ?? []).map { $0.uint64Value }
    }
    func brightness(_ id: UInt64) -> Float {
        let selector = NSSelectorFromString("brightnessForKeyboard:")
        let call = unsafeBitCast(client.method(for: selector), to: (@convention(c) (AnyObject, Selector, UInt64) -> Float).self)
        return call(client, selector, id)
    }
    func builtIn(_ id: UInt64) -> Bool {
        let selector = NSSelectorFromString("isKeyboardBuiltIn:")
        let call = unsafeBitCast(client.method(for: selector), to: (@convention(c) (AnyObject, Selector, UInt64) -> Bool).self)
        return call(client, selector, id)
    }
    func automatic(_ id: UInt64) -> Bool {
        let selector = NSSelectorFromString("isAutoBrightnessEnabledForKeyboard:")
        let call = unsafeBitCast(client.method(for: selector), to: (@convention(c) (AnyObject, Selector, UInt64) -> Bool).self)
        return call(client, selector, id)
    }
    func setBrightness(_ value: Float, _ id: UInt64) -> Bool {
        let selector = NSSelectorFromString("setBrightness:forKeyboard:")
        let call = unsafeBitCast(client.method(for: selector), to: (@convention(c) (AnyObject, Selector, Float, UInt64) -> Bool).self)
        return call(client, selector, value, id)
    }
    func setAutomatic(_ value: Bool, _ id: UInt64) -> Bool {
        let selector = NSSelectorFromString("enableAutoBrightness:forKeyboard:")
        let call = unsafeBitCast(client.method(for: selector), to: (@convention(c) (AnyObject, Selector, Bool, UInt64) -> Bool).self)
        return call(client, selector, value, id)
    }
}

@MainActor
final class KeyboardBacklightController {
    struct SavedKeyboard: Codable {
        let id: UInt64
        let brightness: Float
        let automatic: Bool
    }
    struct Record: Codable {
        let token: UUID
        let owner: Int32
        let boot: String
        let keyboards: [SavedKeyboard]
    }
    static var journalURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Agent Guard/keyboard-recovery.json")
    }
    private var pipe: Pipe?
    private var child: Process?
    private var record: Record?
    private var hardware: KeyboardBacklightHardware?
    private let url: URL
    private let startWatchdog: Bool
    init(url: URL = journalURL, startWatchdog: Bool = true) {
        self.url = url
        self.startWatchdog = startWatchdog
    }
    private static func bootSession() -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    private func locked<T>(_ action: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let fd = open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw KeyboardBacklightHardware.Failure(message: "无法打开键盘背光恢复锁。") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw KeyboardBacklightHardware.Failure(message: "键盘背光正在恢复。") }
        defer { flock(fd, LOCK_UN) }
        return try action()
    }
    private func load() throws -> Record? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
    }
    func turnOff() -> String? {
        do {
            if record == nil {
                if let error = restore() { return error }
                let hw = try KeyboardBacklightHardware()
                let keyboards = hw.ids.filter { hw.builtIn($0) }.prefix(1).map { SavedKeyboard(id: $0, brightness: hw.brightness($0), automatic: hw.automatic($0)) }
                guard !keyboards.isEmpty else { return nil }
                guard keyboards.allSatisfy({ $0.brightness.isFinite && (0...1).contains($0.brightness) }),
                      !Self.bootSession().isEmpty else {
                    throw KeyboardBacklightHardware.Failure(message: "无法保存键盘背光原状态。")
                }
                let saved = Record(token: UUID(), owner: getpid(), boot: Self.bootSession(), keyboards: keyboards)
                try locked {
                    guard try load() == nil else { throw KeyboardBacklightHardware.Failure(message: "存在待恢复的键盘背光记录。") }
                    try JSONEncoder().encode(saved).write(to: url, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                }
                record = saved
                hardware = hw
                if startWatchdog {
                    let process = Process()
                    let channel = Pipe()
                    process.executableURL = Bundle.main.executableURL
                    process.arguments = ["--keyboard-recovery-watchdog", saved.token.uuidString]
                    process.standardInput = channel
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    channel.fileHandleForReading.closeFile()
                    child = process
                    pipe = channel
                }
            }
            if startWatchdog && child?.isRunning != true {
                throw KeyboardBacklightHardware.Failure(message: "键盘背光恢复进程不可用。")
            }
            guard let hw = hardware, let saved = record else { return nil }
            for keyboard in saved.keyboards {
                guard hw.setAutomatic(false, keyboard.id), hw.setBrightness(0, keyboard.id),
                      hw.brightness(keyboard.id) <= 0.001 else {
                    throw KeyboardBacklightHardware.Failure(message: "键盘背光未能关闭。")
                }
            }
            return nil
        } catch {
            let recovery = restore()
            return "键盘背光控制失败：\(error)" + (recovery.map { "；\($0)" } ?? "")
        }
    }
    /// Called by the existing guard health timer; do not overwrite the snapshot.
    func keepOff() -> String? {
        guard record != nil else { return nil }
        return turnOff()
    }
    func restore(expectedToken: UUID? = nil) -> String? {
        do {
            try locked {
                guard let saved = try load() else { return }
                if let expectedToken, saved.token != expectedToken { return }
                guard !Self.bootSession().isEmpty else { throw KeyboardBacklightHardware.Failure(message: "无法核验启动会话。") }
                let sameBoot = saved.boot == Self.bootSession()
                if sameBoot {
                    guard saved.owner == getpid() || (kill(saved.owner, 0) != 0 && errno == ESRCH) else {
                        throw KeyboardBacklightHardware.Failure(message: "另一托管进程仍在使用键盘背光。")
                    }
                }
                let hw = try KeyboardBacklightHardware()
                for keyboard in saved.keyboards {
                    // Only the built-in keyboard is managed. Across boots restore its
                    // persistent auto setting, never the stale brightness or device ID.
                    let id = sameBoot ? keyboard.id : hw.ids.first(where: { hw.builtIn($0) })
                    guard let id, hw.ids.contains(id), hw.builtIn(id) else {
                        throw KeyboardBacklightHardware.Failure(message: "内置键盘不可用，背光恢复待重试。")
                    }
                    let brightnessOK = !sameBoot || (hw.setBrightness(keyboard.brightness, id)
                        && abs(hw.brightness(id) - keyboard.brightness) <= 0.01)
                    let automaticOK = hw.setAutomatic(keyboard.automatic, id)
                        && hw.automatic(id) == keyboard.automatic
                    guard brightnessOK && automaticOK else {
                        throw KeyboardBacklightHardware.Failure(message: "键盘背光恢复待重试。")
                    }
                }
                try FileManager.default.removeItem(at: url)
            }
            record = nil
            hardware = nil
            try? pipe?.fileHandleForWriting.write(contentsOf: Data("restored".utf8))
            try? pipe?.fileHandleForWriting.close()
            pipe = nil
            child = nil
            return nil
        } catch { return "键盘背光恢复失败：\(error)" }
    }
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--keyboard-recovery-watchdog" else { return false }
        guard let token = UUID(uuidString: CommandLine.arguments[2]) else { return true }
        let message = FileHandle.standardInput.readDataToEndOfFile()
        if String(data: message, encoding: .utf8) == "restored" { return true }
        let controller = KeyboardBacklightController(startWatchdog: false)
        for _ in 0..<6 {
            if controller.restore(expectedToken: token) == nil { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return true
    }
}
