import Darwin
import Foundation

@MainActor
final class DisplayRecoveryJournal {
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Agent Guard/display-recovery.json")
    }
    let url: URL
    private let writeRecordData: (Data, URL) throws -> Void
    init(url: URL = DisplayRecoveryJournal.defaultURL,
         writeRecordData: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.url = url
        self.writeRecordData = writeRecordData
    }
    func load() throws -> DisplayRecoveryRecord? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(DisplayRecoveryRecord.self, from: Data(contentsOf: url))
    }
    // Called under withRecoveryLock. App-scoped display configuration cannot
    // survive a reboot. Never replay old brightness, IDs or PIDs into a new boot.
    func loadForRecovery(currentBoot: String?) throws -> DisplayRecoveryRecord? {
        guard let record = try load() else { return nil }
        guard let currentBoot, !currentBoot.isEmpty,
              let savedBoot = record.builtIn.bootSession, !savedBoot.isEmpty,
              savedBoot != currentBoot,
              record.external.allSatisfy({ $0.bootSession == savedBoot }) else { return record }
        let archive = url.deletingLastPathComponent().appendingPathComponent("expired-recovery")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let destination = archive.appendingPathComponent(record.token.uuidString + ".json")
        try JSONEncoder().encode(record).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        try clear(record.token)
        return nil
    }
    // Caller holds recovery lock and has checked token/owner. Archive the complete
    // original before removing only explicitly excluded external UUIDs.
    func applyingExclusions(_ record: DisplayRecoveryRecord, excludedUUIDs: Set<String>) throws -> DisplayRecoveryRecord {
        let remaining = DisplayExclusionPolicy.managed(record.external, excluding: excludedUUIDs)
        guard remaining != record.external else { return record }
        guard try load()?.token == record.token else {
            throw DisplayOperationError(message: "显示恢复记录已变化，未应用排除规则。")
        }
        let directory = url.deletingLastPathComponent().appendingPathComponent("excluded-recovery")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let archive = directory.appendingPathComponent(record.token.uuidString + "-" + UUID().uuidString + ".json")
        try JSONEncoder().encode(record).write(to: archive, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        let updated = DisplayRecoveryRecord(token: record.token, ownerPID: record.ownerPID,
                                            builtIn: record.builtIn, brightness: record.brightness, external: remaining)
        try save(updated)
        return updated
    }
    func save(_ record: DisplayRecoveryRecord) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try writeRecordData(JSONEncoder().encode(record), url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func clear(_ token: UUID) throws {
        guard let current = try load() else { return }
        guard current.token == token else { throw DisplayOperationError(message: "显示恢复记录已变化，未覆盖。") }
        try FileManager.default.removeItem(at: url)
    }
    func withRecoveryLock<T>(_ action: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let fd = open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw DisplayOperationError(message: "无法打开显示恢复锁。") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw DisplayOperationError(message: "显示恢复正在进行，请稍后重试。") }
        defer { flock(fd, LOCK_UN) }
        return try action()
    }
}

@MainActor
protocol DisplayRecoveryWatching: AnyObject {
    var isRunning: Bool { get }
    func start(journal: DisplayRecoveryJournal, record: DisplayRecoveryRecord) throws
    func disarm()
}

/// A separate instance of our signed executable waits on a private pipe. EOF
/// without a disarm message means the owning app died; no signal handler does UI.
@MainActor
final class DisplayRecoveryWatchdog: DisplayRecoveryWatching {
    private var child: Process?
    private var pipe: Pipe?
    var isRunning: Bool { child?.isRunning == true }
    func start(journal: DisplayRecoveryJournal, record: DisplayRecoveryRecord) throws {
        guard child == nil, let executable = Bundle.main.executableURL else {
            throw DisplayOperationError(message: "无法启动独立显示恢复进程。")
        }
        let process = Process()
        let channel = Pipe()
        process.executableURL = executable
        process.arguments = ["--display-recovery-watchdog", journal.url.path, record.token.uuidString]
        process.standardInput = channel
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        channel.fileHandleForReading.closeFile()
        child = process
        pipe = channel
    }
    func disarm() {
        try? pipe?.fileHandleForWriting.write(contentsOf: Data("restored".utf8))
        try? pipe?.fileHandleForWriting.close()
        pipe = nil
        child = nil
    }
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.count == 4,
              CommandLine.arguments[1] == "--display-recovery-watchdog" else { return false }
        let url = URL(fileURLWithPath: CommandLine.arguments[2])
        guard let token = UUID(uuidString: CommandLine.arguments[3]), url == DisplayRecoveryJournal.defaultURL else { return true }
        let message = FileHandle.standardInput.readDataToEndOfFile()
        if String(data: message, encoding: .utf8) == "restored" { return true }
        let journal = DisplayRecoveryJournal(url: url)
        let hardware = NativeDisplayHardware()
        // Runs in the independent recovery process, never on the app's event-tap loop.
        for _ in 0..<6 {
            do {
                let done = try journal.withRecoveryLock {
                    guard let record = try journal.loadForRecovery(currentBoot: DisplayBootSession.current()), record.token == token else { return true }
                    guard kill(record.ownerPID, 0) != 0, errno == ESRCH else { return false }
                    let filtered = try journal.applyingExclusions(record, excludedUUIDs: DisplayExclusionPolicy.configuredUUIDs())
                    let errors = DisplayBlackoutController.restore(filtered, hardware: hardware)
                    guard errors.isEmpty else { return false }
                    try journal.clear(token)
                    return true
                }
                if done { return true }
            } catch { /* Retain the journal for startup/manual retry. */ }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return true
    }
}
