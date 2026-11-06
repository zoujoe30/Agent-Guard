import Foundation

@main struct Regression {
    @MainActor static func main() {
        var count = 0
        func check(_ value: Bool, _ description: String) {
            precondition(value, description); count += 1; print("PASS: \(description)")
        }
        var now: Double = 0
        var window: AuthenticationDisplayGate.Window? = nil
        var reasons: [AuthenticationDisplayRestorer.Reason] = []
        let one = AuthenticationDisplayGate.Window(owner: 9, id: 3)
        let two = AuthenticationDisplayGate.Window(owner: 9, id: 4)
        let controller = AuthenticationDisplayRestorer(clock: { now }, sampleWindow: { _ in window }, usesTimer: false)
        controller.start(builtInDisplayID: 1) { reasons.append($0) }
        let g = controller.generation
        controller.poll(generation: g)
        check(reasons.isEmpty, "no window cannot trigger recovery")
        window = one; now = 0.1; controller.poll(generation: g)
        check(reasons.isEmpty, "one observation does not reconnect")
        window = two; now = 0.2; controller.poll(generation: g)
        check(reasons.isEmpty, "changed window restarts confirmation")
        now = 0.3; controller.poll(generation: g)
        check(reasons == [.dialogVisible], "second matching observation reconnects without extra wait")
        now = 0.4; controller.poll(generation: g)
        check(reasons.count == 1, "queued old tick cannot reconnect again")

        reasons = []; now = 1
        controller.start(builtInDisplayID: 1) { reasons.append($0) }
        let h = controller.generation
        window = one; controller.poll(generation: h)
        now = 1.4; controller.poll(generation: h)
        check(reasons.isEmpty, "stale observations cannot confirm readiness")
        window = nil; now = 1.5; controller.poll(generation: h)
        window = one; now = 1.6; controller.poll(generation: h)
        check(reasons.isEmpty, "missing window resets readiness")
        controller.cancel(); now = 1.7; controller.poll(generation: h)
        check(reasons.isEmpty, "cancellation revokes queued recovery")
        controller.start(builtInDisplayID: 1) { reasons.append($0) }
        let j = controller.generation
        controller.poll(generation: h)
        check(reasons.isEmpty, "old session cannot affect a new authentication")
        window = nil; now = 3.2; controller.poll(generation: j)
        check(reasons == [.fallback], "missing UI triggers bounded complete-display fallback")

        var cancelOnSample: (() -> Void)?
        reasons = []; now = 0
        let reentrant = AuthenticationDisplayRestorer(clock: { now }, sampleWindow: { _ in
            cancelOnSample?(); return one
        }, usesTimer: false)
        reentrant.start(builtInDisplayID: 1) { reasons.append($0) }
        let k = reentrant.generation
        reentrant.poll(generation: k)
        cancelOnSample = { reentrant.cancel() }; now = 0.1
        reentrant.poll(generation: k)
        check(reasons.isEmpty, "cancel during sampling never reconnects")
        var focusWindow: AuthenticationDisplayGate.Window? = one
        var focused = true
        var activationRequests = 0
        now = 0
        let focus = AuthenticationFocusRestorer(clock: { now }, observe: {
            .init(window: focusWindow, hasFocus: focused)
        }, activate: { target in
            precondition(target == one); activationRequests += 1; return true
        }, usesTimer: false)
        focus.prepareForDisplayRecovery(); focus.displayRecoveryCompleted()
        let fg = focus.generation
        check(activationRequests == 0, "focused native dialog is never reactivated unnecessarily")
        focused = false; now = 0.1; focus.poll(generation: fg)
        check(activationRequests == 1, "post-reconnect focus loss requests exact native app activation")
        now = 0.2; focus.poll(generation: fg)
        check(activationRequests == 1, "activation acceptance never causes repeated requests")
        focused = true; now = 0.3; focus.poll(generation: fg)
        focused = false; now = 0.4; focus.poll(generation: fg)
        check(activationRequests == 1, "observed focus restoration cancels old monitor")
        focus.prepareForDisplayRecovery(); focus.displayRecoveryCompleted()
        now = 0.5; focus.poll(generation: focus.generation)
        check(activationRequests == 1, "unfocused pre-reconnect session cannot claim focus later")
        focused = true; focus.prepareForDisplayRecovery(); focus.displayRecoveryCompleted()
        let cancelledFocus = focus.generation
        focus.cancel(); focused = false; focus.poll(generation: cancelledFocus)
        check(activationRequests == 1, "authentication teardown revokes queued focus work")
        focused = true; focus.prepareForDisplayRecovery(); focus.displayRecoveryCompleted()
        let changedFocus = focus.generation
        focusWindow = two; focused = false; now += 0.1; focus.poll(generation: changedFocus)
        check(activationRequests == 1, "replacement dialog is never activated by previous session")
        focusWindow = one; focused = true; focus.prepareForDisplayRecovery(); focus.displayRecoveryCompleted()
        let expiredFocus = focus.generation
        now += 1.6; focused = false; focus.poll(generation: expiredFocus)
        check(activationRequests == 1, "focus repair expires and cannot steal focus indefinitely")
        print("Authentication display recovery: \(count)/\(count) checks passed")
    }
}
