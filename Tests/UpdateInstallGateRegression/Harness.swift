import Foundation

@main struct GateRegression {
    @MainActor static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: \(name)") }
            checks += 1
            print("PASS: \(name)")
        }
        var state = GuardState.inactive
        var display = false
        var keyboard = false
        var activating = false
        var snapshots = 0
        let gate = UpdateInstallGate {
            snapshots += 1
            return UpdateInstallGate.Safety(state: state, displayJournalActive: display,
                                           keyboardJournalActive: keyboard, activationInProgress: activating)
        }
        check(!gate.blocksActivation && !gate.hasDeferredInstall, "new gate does not block guarding")
        let session = gate.beginSession()!
        var handlers = 0
        let request = UUID()
        check(gate.submit(session: session, requestID: request) {
            check(gate.blocksActivation, "activation lock is held before installer callback")
            check(!gate.hasDeferredInstall, "pending handler consumed before invoking callback")
            handlers += 1
            check(gate.resumeIfSafe() == .ignored, "reentrant resume cannot repeat callback")
        } == .committed, "safe inactive state commits installation")
        check(handlers == 1, "installation handler invoked once")
        check(gate.blocksActivation, "lock survives return from installation handler")
        check(gate.submit(session: session, requestID: request) { handlers += 100 } == .ignored,
              "duplicate install reply rejected")
        check(gate.beginSession() == nil, "new update session cannot replace committed cycle")
        check(gate.permitsTermination(session: session), "safe committed cycle permits termination")
        state = .guarding
        check(!gate.permitsTermination(session: session), "termination rechecks actual guard state")
        state = .inactive
        display = true
        check(!gate.permitsTermination(session: session), "termination refuses pending display recovery")
        display = false
        keyboard = true
        check(!gate.permitsTermination(session: session), "termination refuses pending keyboard recovery")
        keyboard = false
        check(gate.submit(session: session, requestID: UUID()) {
            check(gate.blocksActivation, "later installation stage retains activation lock")
            handlers += 1
        } == .committed, "later stage in committed cycle can continue")
        check(handlers == 2, "later stage forwarded once")
        check(!gate.finish(session: UUID()) && gate.blocksActivation, "unrelated cancellation cannot unlock committed cycle")
        check(gate.finish(session: session) && !gate.blocksActivation, "matching terminal callback releases lock")
        check(!gate.finish(session: session), "repeated terminal callback is inert")
        check(!gate.permitsTermination(session: session), "finished session cannot authorize termination")

        for blockedState: GuardState in [.guarding, .authenticating, .restoringInput, .recoveryFailed] {
            state = blockedState
            let cycle = gate.beginSession()!
            let before = handlers
            check(gate.submit(session: cycle, requestID: UUID()) { handlers += 1 } == .deferred,
                  "state \(blockedState) defers installation")
            check(handlers == before && gate.hasDeferredInstall && !gate.blocksActivation,
                  "unsafe state neither invokes installer nor reserves activation")
            check(gate.resumeIfSafe() == .deferred && handlers == before, "repeated unsafe resume does not invoke handler")
            state = .inactive
            check(gate.resumeIfSafe() == .committed && handlers == before + 1, "safe transition resumes deferred handler once")
            check(gate.resumeIfSafe() == .ignored && handlers == before + 1, "consumed deferred handler stays consumed")
            _ = gate.finish(session: cycle)
        }
        for which in 0..<3 {
            state = .inactive
            display = which == 0
            keyboard = which == 1
            activating = which == 2
            let cycle = gate.beginSession()!
            let before = handlers
            check(gate.submit(session: cycle, requestID: UUID()) { handlers += 1 } == .deferred,
                  "journal or activation transaction \(which) blocks commit")
            display = false
            keyboard = false
            activating = false
            check(gate.resumeIfSafe() == .committed && handlers == before + 1, "cleared recovery or transaction permits commit")
            _ = gate.finish(session: cycle)
        }
        state = .guarding
        let obsolete = gate.beginSession()!
        let obsoleteRequest = UUID()
        let beforeObsolete = handlers
        check(gate.submit(session: obsolete, requestID: obsoleteRequest) { handlers += 100 } == .deferred,
              "old session initially defers")
        let replacement = gate.beginSession()!
        state = .inactive
        check(gate.resumeIfSafe() == .ignored && handlers == beforeObsolete, "new preinstall cycle invalidates deferred old callback")
        check(gate.submit(session: obsolete, requestID: UUID()) { handlers += 100 } == .ignored,
              "late reply from old session cannot install")
        check(!gate.finish(session: obsolete), "old terminal callback cannot finish newer cycle")
        check(gate.submit(session: replacement, requestID: UUID()) { handlers += 1 } == .committed,
              "replacement cycle can commit independently")
        check(!gate.finish(session: obsolete) && gate.blocksActivation, "old cancellation cannot release new installation lock")
        _ = gate.finish(session: replacement)

        state = .guarding
        let cancelled = gate.beginSession()!
        let cancelBefore = handlers
        _ = gate.submit(session: cancelled, requestID: UUID()) { handlers += 100 }
        check(gate.finish(session: cancelled), "cancel pending cycle succeeds")
        state = .inactive
        check(gate.resumeIfSafe() == .ignored && handlers == cancelBefore, "cancelled pending handler never resumes")
        check(snapshots > 0, "production safety snapshot is consulted")
        print("SUCCESS: \(checks) update installation gate assertions; no Sparkle, installer, UI or hardware operations")
    }
}
