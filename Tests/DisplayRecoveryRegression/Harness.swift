import Foundation
import Darwin

@MainActor final class FakeHardware: DisplayHardware {
    let inner = ManagedDisplay(id: 1, uuid: "builtin")
    let outer = ManagedDisplay(id: 2, uuid: "external")
    var calls: [String] = []
    var capturedExternal: [ManagedDisplay]?
    var enabledIDs: [String] = []
    var failedUUID: String?
    var failOff = false
    var failOn = false
    var failBrightness = false
    var health: String?
    func capture() throws -> DisplayRecoveryRecord {
        calls.append("capture")
        return DisplayRecoveryRecord(token: UUID(), ownerPID: getpid(), builtIn: inner, brightness: 0.7, external: capturedExternal ?? [outer])
    }
    func brightness(_ display: ManagedDisplay, _ value: Float) throws {
        calls.append(value == 0 ? "dark" : "bright")
        if failBrightness { throw DisplayOperationError(message: "brightness failed") }
    }
    func enable(_ display: ManagedDisplay, _ enabled: Bool) throws {
        calls.append(enabled ? "on" : "off")
        enabledIDs.append(display.uuid)
        if display.uuid == failedUUID { throw DisplayOperationError(message: "powered-off TV") }
        if enabled ? failOn : failOff { throw DisplayOperationError(message: "external failed") }
    }
    func blackoutHealth(_ record: DisplayRecoveryRecord) -> String? { health }
}
@MainActor final class FakeWatchdog: DisplayRecoveryWatching {
    var isRunning = false
    var fail = false
    var journalExistedAtStart = false
    func start(journal: DisplayRecoveryJournal, record: DisplayRecoveryRecord) throws {
        journalExistedAtStart = try journal.load()?.token == record.token
        if fail { throw DisplayOperationError(message: "watchdog failed") }
        isRunning = true
    }
    func disarm() { isRunning = false }
}
@main struct Regression {
    @MainActor static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: \(name)") }
            count += 1; print("PASS: \(name)")
        }
        let saved=ManagedDisplay(id:3,uuid:"mi",vendor:25001,model:12289,serial:0,bootSession:"bootA")
        check(saved.matchesOfflineSlot(id:3,online:false,vendor:25001,model:12289,serial:0,boot:"bootA"), "offline original slot recognized without UUID")
        check(!saved.matchesOfflineSlot(id:4,online:false,vendor:25001,model:12289,serial:0,boot:"bootA"), "same-model different slot rejected")
        check(!saved.matchesOfflineSlot(id:3,online:true,vendor:25001,model:12289,serial:0,boot:"bootA"), "online device requires UUID")
        check(!saved.matchesOfflineSlot(id:3,online:false,vendor:25001,model:12289,serial:0,boot:"bootB"), "stale slot after reboot rejected")
        check(!saved.matchesOfflineSlot(id:3,online:false,vendor:0,model:0,serial:0,boot:"bootA"), "ghost slot rejected")
        check(!ManagedDisplay(id:3,uuid:"legacy").matchesOfflineSlot(id:3,online:false,vendor:25001,model:12289,serial:0,boot:"bootA"), "incomplete legacy identity never guessed")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = DisplayRecoveryJournal(url: dir.appendingPathComponent("recovery.json"))
        let hw = FakeHardware(); let watcher = FakeWatchdog()
        let controller = DisplayBlackoutController(hardware: hw, journal: journal, watcher: watcher)
        check(controller.blackOutDisplays() == nil, "blackout succeeds")
        check(watcher.journalExistedAtStart, "journal saved before watchdog/side effects")
        check(hw.calls == ["capture", "off", "dark"], "external disconnect precedes built-in darkness")
        check(controller.blackOutDisplays() == nil && hw.calls.count == 3, "repeated blackout does not overwrite original snapshot")
        hw.calls = []
        hw.failOn = true
        check(controller.restoreDisplays() != nil, "external reconnect failure surfaces")
        check(hw.calls == ["bright", "on"], "internal escape screen restored before external retry")
        check(try! journal.load() != nil, "failed restore retains durable record")
        check(watcher.isRunning, "failed restore keeps crash recovery armed")
        hw.failOn = false
        check(controller.restoreDisplays() == nil, "restore can be retried")
        check(try! journal.load() == nil, "successful restore removes record")
        check(!watcher.isRunning, "watchdog disarmed only after verified restore")
        hw.calls=[]
        check(controller.restoreDisplays() == nil && hw.calls.isEmpty, "restoration is idempotent without extra toggles")
        watcher.fail = true
        check(controller.blackOutDisplays() != nil, "watchdog launch failure refuses blackout")
        check(!hw.calls.contains("off") && !hw.calls.contains("dark"), "watchdog failure never darkens displays")
        watcher.fail=false;hw.calls=[];hw.failOff=true
        check(controller.blackOutDisplays() != nil, "disconnect failure aborts blackout")
        check(!hw.calls.contains("dark"), "disconnect failure keeps internal bright")
        check(hw.calls.suffix(2) == ["bright", "on"], "partial disconnect rolls back")
        hw.failOff=false;hw.calls=[]
        check(controller.blackOutDisplays() == nil, "second cycle captures fresh state")
        hw.health="hotplug"
        check(controller.healthError() == "hotplug", "unexpected hotplug detected")
        watcher.isRunning=false
        check(controller.healthError() != nil, "dead watchdog detected")
        hw.health=nil;_ = controller.restoreDisplays()
        // Simulate an earlier dead process with a valid journal.
        let pending=DisplayRecoveryRecord(token: UUID(), ownerPID: 99999999, builtIn: hw.inner, brightness: 0.6, external:[hw.outer])
        try journal.save(pending)
        let startup=DisplayBlackoutController(hardware:hw,journal:journal,watcher:FakeWatchdog())
        check(startup.restoreDisplays() == nil, "startup restores dead owner's journal")
        check(try! journal.load() == nil, "startup clears journal only on success")
        let live=DisplayRecoveryRecord(token: UUID(), ownerPID:getppid(),builtIn:hw.inner,brightness:0.6,external:[hw.outer])
        try journal.save(live);hw.calls=[]
        check(startup.restoreDisplays() != nil && hw.calls.isEmpty, "live other instance is not touched")
        try journal.clear(live.token)
        let raceHW=FakeHardware();let raceWatcher=FakeWatchdog()
        let raceController=DisplayBlackoutController(hardware:raceHW,journal:journal,watcher:raceWatcher)
        check(raceController.blackOutDisplays() == nil, "prepare token race")
        let newer=DisplayRecoveryRecord(token:UUID(),ownerPID:getpid(),builtIn:hw.inner,brightness:0.8,external:[hw.outer])
        try journal.save(newer);raceHW.calls=[]
        check(raceController.restoreDisplays() != nil && raceHW.calls.isEmpty, "old recovery never touches newer session hardware")
        try journal.clear(newer.token)
        _ = raceController.restoreDisplays()
        let oldInner = ManagedDisplay(id:1,uuid:"builtin",bootSession:"old-boot")
        let oldOuter = ManagedDisplay(id:2,uuid:"missing-external",bootSession:"old-boot")
        let stale = DisplayRecoveryRecord(token:UUID(),ownerPID:getppid(),builtIn:oldInner,brightness:0.6,external:[oldOuter])
        try journal.save(stale); hw.calls=[]
        let rebooted = DisplayBlackoutController(hardware:hw,journal:journal,watcher:FakeWatchdog(),currentBoot:{"new-boot"})
        check(rebooted.restoreDisplays() == nil, "previous boot record expires before PID and hardware access")
        check(hw.calls.isEmpty, "expiry never replays brightness or display changes")
        check(try! journal.load() == nil, "expired record no longer blocks startup")
        let archive = dir.appendingPathComponent("expired-recovery/" + stale.token.uuidString + ".json")
        check((try? JSONDecoder().decode(DisplayRecoveryRecord.self,from:Data(contentsOf:archive)).token) == stale.token, "expired record archived for diagnosis")
        check(rebooted.restoreDisplays() == nil && hw.calls.isEmpty, "expiry is idempotent")
        check(rebooted.blackOutDisplays() == nil, "new blackout allowed after expiry")
        _ = rebooted.restoreDisplays()
        try journal.save(stale)
        check(try! journal.loadForRecovery(currentBoot:"old-boot") != nil, "same boot missing display record retained")
        check(try! journal.loadForRecovery(currentBoot:nil) != nil, "unknown current boot cannot discard recovery")
        try journal.save(pending)
        check(try! journal.loadForRecovery(currentBoot:"new-boot") != nil, "legacy record without boot retained")
        let inconsistent = DisplayRecoveryRecord(token:UUID(),ownerPID:99999999,builtIn:oldInner,brightness:0.6,external:[hw.outer])
        try journal.save(inconsistent)
        check(try! journal.loadForRecovery(currentBoot:"new-boot") != nil, "inconsistent boot metadata retained")
        try journal.clear(inconsistent.token);hw.calls=[]
        try Data("broken".utf8).write(to:journal.url)
        check(startup.blackOutDisplays() != nil && !hw.calls.contains("off"), "corrupt journal blocks blackout")
        let tv = ManagedDisplay(id: 20, uuid: "AAAAAAAA-1111-2222-3333-444444444444", vendor: 8355, model: 48, serial: 1, bootSession: "same-boot")
        let mi = ManagedDisplay(id: 30, uuid: "BBBBBBBB-1111-2222-3333-444444444444", vendor: 25001, model: 12289, serial: 0, bootSession: "same-boot")
        let duplicateModel = ManagedDisplay(id: 40, uuid: "CCCCCCCC-1111-2222-3333-444444444444", vendor: 8355, model: 48, serial: 1, bootSession: "same-boot")
        let excluded: Set<String> = [tv.uuid.lowercased()]
        check(DisplayExclusionPolicy.excludes(tv.uuid, in: excluded), "UUID identity exclusion is case insensitive")
        check(!DisplayExclusionPolicy.excludes(duplicateModel.uuid, in: excluded), "identical hardware fields never exclude a different UUID")
        check(!DisplayExclusionPolicy.excludes("00000000-0000-0000-0000-000000000000", in: ["00000000-0000-0000-0000-000000000000"]), "zero UUID cannot exclude unknown displays")
        check(!DisplayExclusionPolicy.excludes("invalid", in: ["invalid"]), "malformed identities cannot exclude displays")
        check(DisplayExclusionPolicy.managed([tv], excluding: excluded).isEmpty, "excluded TV appearing online does not trigger health failure")
        check(DisplayExclusionPolicy.managed([tv, duplicateModel], excluding: excluded) == [duplicateModel], "non-excluded new online display still triggers health failure")
        let excludedHW = FakeHardware()
        excludedHW.capturedExternal = [tv, mi]
        excludedHW.failedUUID = tv.uuid
        let excludedWatcher = FakeWatchdog()
        let excludedController = DisplayBlackoutController(hardware: excludedHW, journal: journal, watcher: excludedWatcher,
            currentBoot: { "same-boot" }, excludedUUIDs: { excluded })
        let oldTVRecord = DisplayRecoveryRecord(token: UUID(), ownerPID: 99999999, builtIn: hw.inner, brightness: 0.61, external: [tv, mi])
        try journal.save(oldTVRecord)
        check(excludedController.restoreDisplays() == nil, "old powered-off TV record no longer blocks Mi restoration")
        check(excludedHW.enabledIDs == [mi.uuid], "excluded TV is never enabled during old-record restoration")
        check((try! journal.load()) == nil, "fully restored reduced journal can clear")
        let archives = try FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("excluded-recovery"), includingPropertiesForKeys: nil)
        let archived = try JSONDecoder().decode(DisplayRecoveryRecord.self, from: Data(contentsOf: archives[0]))
        check(archived.external == [tv, mi] && archived.token == oldTVRecord.token, "complete original TV record archived before migration")
        check(archived.ownerPID == oldTVRecord.ownerPID && archived.brightness == oldTVRecord.brightness && archived.builtIn == oldTVRecord.builtIn, "archive retains owner and built-in recovery data")
        excludedHW.enabledIDs = []
        check(excludedController.blackOutDisplays() == nil, "new blackout can start with TV excluded")
        check((try! journal.load())?.external == [mi], "new capture journal excludes only TV")
        check(excludedHW.enabledIDs == [mi.uuid], "new blackout never disables excluded TV")
        _ = excludedController.restoreDisplays()
        try journal.save(oldTVRecord)
        excludedHW.enabledIDs = []
        excludedHW.failOn = true
        check(excludedController.restoreDisplays() != nil, "remaining Mi restore failure remains actionable")
        let reduced = try journal.load()!
        check(reduced.external == [mi] && reduced.token == oldTVRecord.token && reduced.ownerPID == oldTVRecord.ownerPID, "failed remaining display retains reduced journal and ownership")
        check(reduced.brightness == oldTVRecord.brightness && reduced.builtIn == oldTVRecord.builtIn, "migration preserves exact built-in restoration values")
        excludedHW.failOn = false
        _ = excludedController.restoreDisplays()
        let liveTVRecord = DisplayRecoveryRecord(token: UUID(), ownerPID: getppid(), builtIn: hw.inner, brightness: 0.6, external: [tv, mi])
        try journal.save(liveTVRecord)
        let archiveCount = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("excluded-recovery").path).count
        check(excludedController.restoreDisplays() != nil, "live owner prevents exclusion migration")
        check((try! journal.load())?.external == [tv, mi], "live owner's full record remains untouched")
        check((try! FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("excluded-recovery").path)).count == archiveCount, "owner checked before exclusion archive")
        try journal.clear(liveTVRecord.token)
        // Block archive creation with a regular file; journal must remain intact.
        let failureDir = dir.appendingPathComponent("archive-failure")
        let failureJournal = DisplayRecoveryJournal(url: failureDir.appendingPathComponent("recovery.json"))
        try failureJournal.save(oldTVRecord)
        try Data("blocked".utf8).write(to: failureDir.appendingPathComponent("excluded-recovery"))
        let failureHW = FakeHardware()
        let failureController = DisplayBlackoutController(hardware: failureHW, journal: failureJournal, watcher: FakeWatchdog(), excludedUUIDs: { excluded })
        check(failureController.restoreDisplays() != nil, "archive failure refuses exclusion migration")
        check((try! failureJournal.load())?.external == [tv, mi], "archive failure preserves full original journal")
        check(failureHW.calls.isEmpty, "archive failure causes no display operations")
        do {
            let staleTokenRecord = DisplayRecoveryRecord(token: UUID(), ownerPID: oldTVRecord.ownerPID, builtIn: oldTVRecord.builtIn, brightness: 0.5, external: [tv])
            _ = try journal.withRecoveryLock { try journal.applyingExclusions(staleTokenRecord, excludedUUIDs: excluded) }
            fatalError("FAIL: missing token accepted")
        } catch { check(true, "migration rejects missing or changed journal token") }
        var rejectSave = false
        let saveFailureJournal = DisplayRecoveryJournal(url: dir.appendingPathComponent("save-failure/recovery.json"), writeRecordData: { data, url in
            if rejectSave { throw DisplayOperationError(message: "injected atomic-save failure") }
            try data.write(to: url, options: .atomic)
        })
        try saveFailureJournal.save(oldTVRecord)
        rejectSave = true
        let saveFailureHW = FakeHardware()
        let saveFailureController = DisplayBlackoutController(hardware: saveFailureHW, journal: saveFailureJournal, watcher: FakeWatchdog(), excludedUUIDs: { excluded })
        check(saveFailureController.restoreDisplays() != nil, "reduced journal save failure aborts recovery")
        check((try! saveFailureJournal.load())?.external == [tv, mi], "save failure leaves original durable journal")
        check(saveFailureHW.calls.isEmpty, "save failure never proceeds to display operations or clear")
        check((try! FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("save-failure/excluded-recovery").path)).count == 1, "original is archived even when reduced journal save fails")
        print("Display recovery: \(count)/\(count) checks passed")
    }
}
