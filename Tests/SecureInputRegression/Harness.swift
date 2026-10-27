import Foundation
import AgentGuardCore

@main struct Regression {
    @MainActor static func main() {
        var checks = 0
        func check(_ ok: @autoclosure () -> Bool, _ name: String) {
            guard ok() else { fatalError("FAIL: \(name)") }
            checks += 1
            print("PASS: \(name)")
        }
        let suite = "com.local.agentguard.regression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var secure = true
        let controller = GuardController(defaults: defaults, secureInputStatus: {
            SecureInputStatus(enabled: secure, ownerPID: secure ? 123 : nil, ownerName: secure ? "Terminal" : nil)
        }, monitorHealth: false, permissionCheck: { _ in true })
        let initialMode = controller.displayMode
        controller.toggleDisplayPreferenceFromShortcut()
        check(controller.displayMode != initialMode, "inactive display shortcut changes preference")
        check(DisplayBlackoutController.blackoutCount == 0, "inactive toggle does not black out hardware")
        controller.toggleDisplayPreferenceFromShortcut()
        check(controller.displayMode == initialMode, "second toggle restores preference")
        controller.activate()
        check(controller.state == .inactive, "secure input blocks activation even with healthy tap")
        check(PowerAssertionController.applyCount == 0, "blocked activation does not acquire power assertions")
        check(DisplayBlackoutController.blackoutCount == 0, "blocked activation never blacks out")
        secure = false
        controller.activate()
        check(controller.state == .guarding, "normal activation works")
        let guardedMode = controller.displayMode
        controller.toggleDisplayPreferenceFromShortcut()
        check(controller.displayMode == guardedMode, "controller rejects display shortcut while guarding")
        secure = true
        let restores = DisplayBlackoutController.restoreCount
        controller.checkInputHealth()
        check(controller.state == .recoveryFailed, "secure input during guarding enters fault state")
        check(DisplayBlackoutController.restoreCount > restores, "fault restores display")
        controller.toggleDisplayPreferenceFromShortcut()
        check(controller.displayMode == guardedMode, "controller rejects display shortcut in fault state")
        InputBlocker.healthy = false
        controller.beginAuthentication()
        check(controller.state == .authenticating, "mouse authentication remains available with unhealthy tap and secure input")
        controller.toggleDisplayPreferenceFromShortcut()
        check(controller.displayMode == guardedMode, "controller rejects display shortcut during authentication")
        check(AuthenticationController.count == 1, "recovery reaches authentication provider")
        controller.checkInputHealth()
        check(controller.state == .authenticating, "secure input polling does not cancel authentication")
        check(AuthenticationController.pending != nil, "authentication callback remains pending")
        AuthenticationController.finish(.failed("test cancellation"))
        check(controller.state == .restoringInput, "failed authentication waits with input blocked while secure input enabled")
        check(DisplayBlackoutController.blackoutCount == 0, "failed authentication cannot black out while secure input enabled")
        controller.beginAuthentication()
        AuthenticationController.finish(.success)
        check(controller.state == .inactive, "successful recovery authentication deactivates")
        InputBlocker.healthy = true
        secure = false
        controller.activate()
        secure = true
        let blackouts = DisplayBlackoutController.blackoutCount
        let error = controller.setDisplayMode(.managedBlackout)
        check(error != nil, "blackout switch fails under secure input")
        check(controller.state == .recoveryFailed, "blackout switch detects fault immediately")
        check(DisplayBlackoutController.blackoutCount == blackouts, "blackout is never attempted under secure input")
        controller.beginAuthentication()
        AuthenticationController.finish(.timedOut)
        check(controller.state == .restoringInput, "timeout waits without reporting unsafe guarding")
        secure = false
        controller.beginAuthentication()
        AuthenticationController.finish(.failed("cancelled"))
        check(controller.state == .guarding, "cancelled recovery authentication resumes only after input is safe")
        controller.deactivate()
        InputBlocker.healthy = false
        controller.activate()
        check(controller.state == .inactive, "tap installation failure still blocks activation")
        InputBlocker.healthy = true
        secure = false
        _ = controller.setDisplayMode(.managedBlackout)
        let beforeRaceBlackouts = DisplayBlackoutController.blackoutCount
        let beforeRacePower = PowerAssertionController.applyCount
        InputBlocker.onInstall = { secure = true }
        controller.activate()
        check(controller.state == .inactive, "secure enabled by tap initialization blocks activation")
        check(PowerAssertionController.applyCount == beforeRacePower, "post-install secure check runs before power acquisition")
        check(DisplayBlackoutController.blackoutCount == beforeRaceBlackouts, "tap initialization race never blacks out")
        InputBlocker.onInstall = nil
        secure = false
        PowerAssertionController.onApply = { secure = true }
        controller.activate()
        check(controller.state == .inactive, "secure enabled immediately before blackout blocks activation")
        check(DisplayBlackoutController.blackoutCount == beforeRaceBlackouts, "last-moment secure check prevents blackout invocation")
        PowerAssertionController.onApply = nil
        secure = false
        controller.activate()
        check(controller.state == .guarding, "managed blackout activates with safe input")
        check(DisplayBlackoutController.blackoutCount == beforeRaceBlackouts + 1, "safe managed blackout reaches display provider")
        controller.beginAuthentication()
        InputBlocker.onInstall = { secure = true }
        AuthenticationController.finish(.failed("cancelled"))
        check(controller.state == .restoringInput, "resume tap race keeps restricted restoration state")
        check(DisplayBlackoutController.blackoutCount == beforeRaceBlackouts + 1, "resume tap race never re-enters blackout")
        InputBlocker.onInstall = nil
        controller.deactivate()
        secure = false
        let monitored = GuardController(defaults: defaults, secureInputStatus: {
            SecureInputStatus(enabled: secure, ownerPID: nil, ownerName: nil)
        }, monitorHealth: true, permissionCheck: { _ in true })
        func timer(_ instance: GuardController) -> Timer? {
            let child = Mirror(reflecting: instance).children.first { $0.label == "healthTimer" }!
            return child.value as? Timer
        }
        check(timer(monitored) == nil, "inactive controller has no health timer")
        monitored.activate()
        let firstTimer = timer(monitored)
        check(firstTimer?.isValid == true, "entering guarding starts health timer")
        monitored.beginAuthentication()
        check(firstTimer?.isValid == false && timer(monitored) == nil, "authentication invalidates and clears health timer")
        AuthenticationController.finish(.failed("cancelled"))
        let resumedTimer = timer(monitored)
        check(resumedTimer?.isValid == true, "resuming guarding restarts health timer")
        secure = true
        monitored.checkInputHealth()
        check(resumedTimer?.isValid == false && timer(monitored)?.isValid == true, "fault transition retains recovery health monitoring")
        monitored.deactivate()
        secure = false
        monitored.activate()
        DisplayBlackoutController.healthFailure = "hotplug"
        monitored.checkInputHealth()
        check(monitored.state == .recoveryFailed, "display health failure enters recovery state")
        DisplayBlackoutController.healthFailure = nil
        DisplayBlackoutController.restoreFailure = "external reconnect failed"
        let authCount = AuthenticationController.count
        monitored.beginAuthentication()
        check(monitored.state == .authenticating, "powered-off external does not gate authentication")
        check(AuthenticationController.count == authCount + 1, "restore failure still opens auth prompt")
        AuthenticationController.finish(.timedOut)
        check(monitored.state == .recoveryFailed, "recovery timeout keeps fault without resuming blackout")
        monitored.beginAuthentication()
        AuthenticationController.finish(.failed("cancelled"))
        check(monitored.state == .recoveryFailed, "recovery cancellation does not re-enter guarding")
        var recoveryMessage: String?
        monitored.onStateChange = { _, message in recoveryMessage = message }
        monitored.beginAuthentication()
        AuthenticationController.finish(.success)
        check(monitored.state == .inactive, "successful authentication releases input despite external failure")
        check(recoveryMessage?.contains("显示恢复待完成") == true, "pending display recovery remains visible after authentication")
        _ = monitored.setDisplayMode(.managedBlackout)
        check(recoveryMessage?.contains("显示恢复待完成") == true, "display preference change preserves unresolved display warning")
        let beforeRetry = DisplayBlackoutController.restoreCount
        monitored.retryDisplayRecovery()
        check(DisplayBlackoutController.restoreCount == beforeRetry + 1, "inactive display retry is independent of input authentication")
        check(monitored.state == .inactive, "failed display retry never relocks input")
        monitored.activate()
        check(monitored.state == .inactive, "pending display recovery prevents unsafe new blackout")
        DisplayBlackoutController.restoreFailure = nil
        monitored.retryDisplayRecovery()
        check(recoveryMessage == "显示恢复已完成。", "powered-on television retry clears warning")
        check(monitored.state == .inactive, "display retry leaves authenticated input inactive")
        DisplayBlackoutController.restoreFailure = "TV off during startup"
        let startup = GuardController(defaults: defaults, monitorHealth: false, permissionCheck: { _ in true })
        check(startup.recoverDisplaysOnLaunch() != nil && startup.state == .recoveryFailed, "startup with unresolved journal preserves authentication requirement")
        startup.beginAuthentication()
        check(startup.state == .authenticating, "startup recovery failure still permits identity verification")
        AuthenticationController.finish(.success)
        check(startup.state == .inactive, "startup authentication succeeds with TV still off")
        DisplayBlackoutController.restoreFailure = nil
        let keyboardTest = GuardController(defaults: defaults, secureInputStatus: {
            SecureInputStatus(enabled: false, ownerPID: nil, ownerName: nil)
        }, monitorHealth: false, permissionCheck: { _ in true })
        var keyboardMessage: String?
        keyboardTest.onStateChange = { _, message in keyboardMessage = message }
        let offBefore = KeyboardBacklightController.offCount
        keyboardTest.activate()
        check(KeyboardBacklightController.offCount == offBefore + 1, "guard activation turns keyboard backlight off")
        let restoreBefore = KeyboardBacklightController.restoreCount
        keyboardTest.beginAuthentication()
        check(KeyboardBacklightController.restoreCount == restoreBefore + 1, "authentication restores keyboard backlight")
        AuthenticationController.finish(.timedOut)
        check(KeyboardBacklightController.offCount == offBefore + 2, "authentication timeout turns keyboard backlight off again")
        KeyboardBacklightController.healthError = "keyboard health failure"
        keyboardTest.checkInputHealth()
        check(keyboardTest.state == .recoveryFailed, "keyboard health failure enters explicit recovery state")
        check(keyboardMessage?.contains("keyboard health failure") == true, "keyboard health failure remains visible")
        KeyboardBacklightController.healthError = nil
        DisplayBlackoutController.restoreFailure = "display recovery failure"
        KeyboardBacklightController.restoreError = "keyboard recovery failure"
        let restoreAtLaunch = KeyboardBacklightController.restoreCount
        _ = keyboardTest.recoverDisplaysOnLaunch()
        check(KeyboardBacklightController.restoreCount > restoreAtLaunch, "display startup failure never skips keyboard restoration")
        keyboardTest.deactivate()
        check(keyboardMessage?.contains("keyboard recovery failure") == true && keyboardMessage?.contains("display recovery failure") == true,
              "display and keyboard recovery failures both remain visible")
        DisplayBlackoutController.restoreFailure = nil
        KeyboardBacklightController.restoreError = nil
        KeyboardBacklightController.offError = "initial backlight failure"
        keyboardTest.activate()
        check(keyboardTest.state != .guarding, "initial keyboard failure never reports normal guarding")
        check(keyboardMessage?.contains("initial backlight failure") == true, "initial keyboard failure remains visible")
        KeyboardBacklightController.offError = nil
        // Regression for coreautha releasing Secure Input AFTER the timeout callback.
        var teardownSecure = false
        var now: TimeInterval = 100
        let teardown = GuardController(defaults: defaults, secureInputStatus: {
            SecureInputStatus(enabled: teardownSecure, ownerPID: 777, ownerName: "coreautha")
        }, monitorHealth: true, permissionCheck: { _ in true }, monotonicNow: { now })
        teardown.activate()
        check(teardown.state == .guarding, "teardown regression starts guarding")
        teardown.beginAuthentication()
        teardownSecure = true
        AuthenticationController.finish(.timedOut)
        check(teardown.state == .restoringInput, "timeout retains restricted teardown while coreautha secure input lingers")
        check(InputBlocker.lastState == .restoringInput, "timeout revokes authentication input allowance immediately")
        check(timer(teardown)?.isValid == true, "teardown keeps automatic recovery polling")
        let noBlackout = DisplayBlackoutController.blackoutCount
        teardown.checkInputHealth()
        check(DisplayBlackoutController.blackoutCount == noBlackout, "secure teardown cannot black out displays")
        now += 4
        teardown.checkInputHealth()
        check(teardown.state == .recoveryFailed && InputBlocker.lastState == .recoveryFailed, "persistent secure input produces restricted visible fault")
        check(timer(teardown)?.isValid == true, "persistent teardown fault continues polling")
        teardownSecure = false
        teardown.checkInputHealth()
        check(teardown.state == .guarding && InputBlocker.lastState == .guarding, "late secure input release restores actual guarding automatically")
        teardown.beginAuthentication()
        teardownSecure = true
        AuthenticationController.finish(.failed("cancelled"))
        check(teardown.state == .restoringInput, "cancelled password fallback also waits for secure teardown")
        teardown.beginAuthentication()
        check(teardown.state == .authenticating, "space retry can start a new authentication during teardown")
        teardown.checkInputHealth()
        check(teardown.state == .authenticating, "old teardown polling cannot overwrite a new authentication")
        AuthenticationController.finish(.success)
        check(teardown.state == .inactive && InputBlocker.lastState == .inactive, "only successful authentication releases physical input")
        teardownSecure = false
        teardown.activate()
        teardown.beginAuthentication()
        teardownSecure = true
        AuthenticationController.finish(.timedOut)
        teardown.deactivate()
        teardownSecure = false
        teardown.checkInputHealth()
        check(teardown.state == .inactive, "deactivation cancels pending automatic resumption")
        keyboardTest.deactivate()
        let updateTest = GuardController(defaults: defaults, secureInputStatus: {
            SecureInputStatus(enabled: false, ownerPID: nil, ownerName: nil)
        }, monitorHealth: false, permissionCheck: { _ in true })
        var allowActivation = false
        var transactionObserved = false
        var transactionEnded = false
        updateTest.activationAllowed = {
            transactionObserved = updateTest.activationInProgress
            return allowActivation
        }
        updateTest.onStateChange = { _, _ in
            if !updateTest.activationInProgress { transactionEnded = true }
        }
        let updatePowerBefore = PowerAssertionController.applyCount
        updateTest.activate()
        check(transactionObserved, "update admission check occurs inside activation transaction")
        check(updateTest.state == .inactive && PowerAssertionController.applyCount == updatePowerBefore,
              "update lock rejects activation before power effects")
        check(!updateTest.activationInProgress && transactionEnded,
              "rejected activation clears transaction and notifies observers")
        allowActivation = true
        PowerAssertionController.onApply = { allowActivation = false }
        let updateRestoreBefore = DisplayBlackoutController.restoreCount
        updateTest.activate()
        check(updateTest.state == .inactive && !updateTest.activationInProgress,
              "late installation lock prevents guarding commit")
        check(DisplayBlackoutController.restoreCount > updateRestoreBefore,
              "late installation lock rolls back display effects")
        PowerAssertionController.onApply = nil
        check(updateTest.installationSafety.permitsInstallation,
              "clean inactive transaction is safe for installation")
        let testJournals = [DisplayRecoveryJournal.defaultURL, KeyboardBacklightController.journalURL]
        for (index, journal) in testJournals.enumerated() {
            try! FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data("pending recovery".utf8).write(to: journal)
            check(!updateTest.installationSafety.permitsInstallation, "real journal existence blocks installation index=\(index)")
            try! FileManager.default.removeItem(at: journal.deletingLastPathComponent())
        }
        allowActivation = true
        updateTest.activate()
        check(updateTest.state == .guarding && !updateTest.installationSafety.permitsInstallation,
              "guarding never presents installation-safe snapshot")
        updateTest.deactivate()
        print("SUCCESS: \(checks) regression assertions; no physical input, display or authentication operations")
    }
}
