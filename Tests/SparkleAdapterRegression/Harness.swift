import AppKit
import Foundation
import Sparkle

@main struct AdapterRegression {
    @MainActor static func main() {
        var checks = 0
        func check(_ ok: @autoclosure () -> Bool, _ name: String) {
            guard ok() else { fatalError("FAIL: \(name)") }
            checks += 1
            print("PASS: \(name)")
        }
        var state = GuardState.inactive
        var displayRecovery = false
        var keyboardRecovery = false
        let controller = SparkleUpdateController {
            UpdateInstallGate.Safety(state: state, displayJournalActive: displayRecovery,
                                    keyboardJournalActive: keyboardRecovery)
        }
        let updater = SPUUpdater.latest!
        let item = SUAppcastItem()
        let failure = NSError(domain: "test.update", code: 1)
        func begin() { try! controller.updater(updater, mayPerform: .updates) }
        func finishError() { controller.updater(updater, didAbortWithError: failure) }
        var installs = 0
        for stage: SPUUserUpdateStage in [.notDownloaded, .downloaded, .installing] {
            begin()
            controller.showUpdateFound(with: item, state: SPUUserUpdateState(stage: stage)) { choice in
                check(choice == .install, "adapter forwards actual install choice")
                check(controller.blocksActivation, "found reply acquires lock before forwarding")
                installs += 1
            }
            let reply = SPUStandardUserDriver.foundReply!
            reply(.install)
            let before = installs
            reply(.install)
            check(installs == before, "duplicate found install callback is consumed once stage=\(stage)")
            check(controller.blocksActivation, "found stage=\(stage) keeps installation lock")
            controller.updater(updater, didFinishUpdateCycleFor: .updates, error: nil)
            check(controller.blocksActivation, "successful cycle does not unlock prepared installer")
            finishError()
            check(!controller.blocksActivation, "confirmed update abort releases lock")
        }
        check(installs == 3, "all three found stages route through gate")

        begin()
        state = .authenticating
        controller.showReady(toInstallAndRelaunch: { choice in
            check(controller.blocksActivation && state == .inactive, "ready install is admitted only after authentication ends")
            installs += 1
        })
        SPUStandardUserDriver.readyReply!(.install)
        check(controller.hasDeferredInstall && !controller.blocksActivation, "ready install defers during authentication")
        controller.guardStateDidChange()
        check(controller.hasDeferredInstall, "repeated unsafe state notification preserves deferred install")
        state = .inactive
        displayRecovery = true
        controller.guardStateDidChange()
        check(controller.hasDeferredInstall, "adapter will not install over display recovery")
        displayRecovery = false
        keyboardRecovery = true
        controller.guardStateDidChange()
        check(controller.hasDeferredInstall, "adapter will not install over keyboard recovery")
        keyboardRecovery = false
        let beforeReady = installs
        controller.guardStateDidChange()
        controller.guardStateDidChange()
        check(installs == beforeReady + 1 && !controller.hasDeferredInstall, "safe notification forwards ready reply exactly once")
        controller.dismissUpdateInstallation()
        check(controller.blocksActivation, "dismissing update UI does not release installer lease")

        controller.showReady(toInstallAndRelaunch: { choice in
            check(choice == .skip && controller.blocksActivation, "skip request forwards while lease is still held")
        })
        SPUStandardUserDriver.readyReply!(.skip)
        check(controller.blocksActivation, "skip does not release lock before asynchronous Sparkle cancellation")
        controller.updater(updater, didFinishUpdateCycleFor: .updates, error: nil)
        check(!controller.blocksActivation, "terminal skip cycle confirms cancellation and releases lock")

        begin()
        state = .guarding
        var postponed = 0
        check(controller.updater(updater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: {
            check(controller.blocksActivation, "postponed handler runs under installation lease")
            postponed += 1
        }), "delegate always postpones until gate admission")
        check(controller.hasDeferredInstall && postponed == 0, "postponed install waits through guarding")
        state = .inactive
        controller.guardStateDidChange()
        check(postponed == 1, "postponed delegate handler resumes once")
        finishError()

        begin()
        var retries = 0
        controller.showInstallingUpdate(withApplicationTerminated: false) {
            check(controller.blocksActivation, "retry termination runs under installation lease")
            retries += 1
        }
        let oldRetry = SPUStandardUserDriver.retryTermination!
        finishError()
        begin()
        oldRetry()
        check(retries == 0 && !controller.blocksActivation, "old retry callback cannot acquire new session lease or terminate")
        controller.showInstallingUpdate(withApplicationTerminated: false) { retries += 1 }
        let currentRetry = SPUStandardUserDriver.retryTermination!
        currentRetry()
        currentRetry()
        check(retries == 1 && controller.blocksActivation, "current retry is guarded and consumed once")
        finishError()

        begin()
        controller.showUpdateFound(with: item, state: SPUUserUpdateState(stage: .notDownloaded)) { _ in installs += 100 }
        let oldFound = SPUStandardUserDriver.foundReply!
        finishError()
        begin()
        let beforeOld = installs
        oldFound(.install)
        check(installs == beforeOld && !controller.blocksActivation, "expired found reply cannot install new cycle")
        finishError()
        state = .guarding
        do {
            try controller.updater(updater, mayPerform: .updates)
            fatalError("FAIL: guarded mayPerform must reject")
        } catch { check(true, "updater cycle admission rejects guarding") }
        state = .inactive
        controller.showInstallingUpdate(withApplicationTerminated: true) { retries += 100 }
        SPUStandardUserDriver.retryTermination!()
        check(retries == 1, "already terminated application never receives retry")
        print("SUCCESS: \(checks) assertions exercise real SparkleUpdateController against a non-UI Sparkle module stub")
    }
}
