import Darwin
import Foundation

@MainActor
final class DisplayBlackoutController {
    private let hardware: any DisplayHardware
    private let journal: DisplayRecoveryJournal
    private let watcher: any DisplayRecoveryWatching
    private let currentBoot: () -> String?
    private let excludedUUIDs: () -> Set<String>
    private var record: DisplayRecoveryRecord?
    init(hardware: any DisplayHardware = NativeDisplayHardware(),
         journal: DisplayRecoveryJournal = DisplayRecoveryJournal(),
         watcher: any DisplayRecoveryWatching = DisplayRecoveryWatchdog(),
         currentBoot: @escaping () -> String? = { DisplayBootSession.current() },
         excludedUUIDs: @escaping () -> Set<String> = { DisplayExclusionPolicy.configuredUUIDs() }) {
        self.excludedUUIDs = excludedUUIDs
        self.currentBoot = currentBoot
        self.hardware = hardware
        self.journal = journal
        self.watcher = watcher
    }
    func blackOutDisplays() -> String? {
        if let record { return hardware.blackoutHealth(record) ?? (watcher.isRunning ? nil : "独立显示恢复进程已停止。") }
        do {
            return try journal.withRecoveryLock {
            guard try journal.loadForRecovery(currentBoot: currentBoot()) == nil else { return "尚有未完成的显示恢复，请先恢复显示后重试。" }
            let captured = try hardware.capture()
            let snapshot = DisplayRecoveryRecord(token: captured.token, ownerPID: captured.ownerPID,
                builtIn: captured.builtIn, brightness: captured.brightness,
                external: DisplayExclusionPolicy.managed(captured.external, excluding: excludedUUIDs()))
            // Journal and recovery process exist BEFORE any display is changed.
            try journal.save(snapshot)
            record = snapshot
            try watcher.start(journal: journal, record: snapshot)
            guard watcher.isRunning else { throw DisplayOperationError(message: "独立显示恢复进程未运行。") }
            // Keep the visible built-in escape screen until all externals disconnect.
            for external in snapshot.external { try hardware.enable(external, false) }
            try hardware.brightness(snapshot.builtIn, 0)
            if let error = hardware.blackoutHealth(snapshot) { throw DisplayOperationError(message: error) }
            return nil
            }
        } catch {
            let restoreError = restoreDisplays()
            return error.localizedDescription + (restoreError.map { " 回滚未完成：\($0)" } ?? "")
        }
    }
    func restoreDisplays() -> String? {
        do {
            return try journal.withRecoveryLock {
                guard let pending = try journal.loadForRecovery(currentBoot: currentBoot()) else {
                    record = nil
                    watcher.disarm()
                    return nil
                }
                if let record, record.token != pending.token {
                    return "显示恢复记录已变化，拒绝恢复其他托管会话。"
                }
                if pending.ownerPID != getpid() {
                    let result = kill(pending.ownerPID, 0)
                    guard result != 0, errno == ESRCH else {
                        return "另一个 Agent Guard 实例仍在管理显示器，或无法安全核验其退出状态。"
                    }
                }
                let filtered = try journal.applyingExclusions(pending, excludedUUIDs: excludedUUIDs())
                let errors = Self.restore(filtered, hardware: hardware)
                guard errors.isEmpty else { record = filtered; return errors.joined(separator: "；") }
                try journal.clear(pending.token)
                record = nil
                watcher.disarm()
                return nil
            }
        } catch { return "显示恢复未完成：\(error.localizedDescription)" }
    }
    static func restore(_ pending: DisplayRecoveryRecord, hardware: any DisplayHardware) -> [String] {
        var errors: [String] = []
        // Always brighten the built-in screen first, even if an external is missing.
        do { try hardware.brightness(pending.builtIn, pending.brightness) }
        catch { errors.append(error.localizedDescription) }
        for display in pending.external {
            do { try hardware.enable(display, true) }
            catch { errors.append(error.localizedDescription) }
        }
        return errors
    }
    func healthError() -> String? {
        guard let record else { return nil }
        guard watcher.isRunning else { return "独立显示恢复进程意外停止。" }
        return hardware.blackoutHealth(record)
    }
}
