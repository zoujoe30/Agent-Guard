import Foundation

@MainActor
private final class FakeContext: AuthenticationContext {
    var localizedCancelTitle: String?
    var available = true
    var events: [String] = []
    var reply: (@Sendable (Bool, Error?) -> Void)?
    var onInvalidate: (() -> Void)?
    func canAuthenticate(error: NSErrorPointer) -> Bool {
        if !available { error?.pointee = NSError(domain: "test.authentication", code: 7,
                                                userInfo: [NSLocalizedDescriptionKey: "test unavailable"]) }
        events.append("canEvaluate")
        return available
    }
    func evaluate(reason: String, reply: @escaping @Sendable (Bool, Error?) -> Void) {
        events.append("evaluate")
        self.reply = reply
    }
    func invalidate() {
        events.append("invalidate")
        onInvalidate?()
    }
    func respond(success: Bool) { reply?(success, nil) }
}

@main struct AuthenticationLifecycleRegression {
    @MainActor static func main() async {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: \(name)") }
            checks += 1
            print("PASS: \(name)")
        }
        func outcome(_ value: AuthenticationController.Outcome) -> String {
            switch value {
            case .success: return "success"
            case .timedOut: return "timeout"
            case .failed: return "failed"
            }
        }
        func drain() async { try? await Task.sleep(for: .milliseconds(20)) }

        let successContext = FakeContext()
        let successController = AuthenticationController(makeContext: { successContext })
        var successOrder: [String] = []
        successContext.onInvalidate = { successOrder.append("invalidate") }
        successController.authenticate(timeout: 60, willFinish: { successOrder.append("revoke") }) {
            successOrder.append(outcome($0))
        }
        check(successContext.localizedCancelTitle == "取消", "real controller configures context")
        check(successContext.events == ["canEvaluate", "evaluate"], "real controller evaluates provider")
        successContext.respond(success: true)
        await drain()
        check(successOrder == ["revoke", "invalidate", "success"], "success revokes allowance before invalidation and completion")
        successContext.respond(success: true)
        await drain()
        check(successOrder.count == 3, "duplicate success callback cannot finish twice")
        successController.cancel()
        check(successOrder.count == 3, "cancel after completed attempt is inert")

        let timeoutContext = FakeContext()
        let timeoutController = AuthenticationController(makeContext: { timeoutContext })
        var timeoutOrder: [String] = []
        timeoutContext.onInvalidate = {
            timeoutOrder.append("invalidate")
            // Simulate a reply synchronously delivered while invalidate runs.
            timeoutContext.respond(success: true)
        }
        timeoutController.authenticate(timeout: 0, willFinish: { timeoutOrder.append("revoke") }) {
            timeoutOrder.append(outcome($0))
        }
        await drain()
        check(timeoutOrder == ["revoke", "invalidate", "timeout"], "timeout revokes before invalidation and ignores reentrant success")
        timeoutContext.respond(success: true)
        await drain()
        check(timeoutOrder == ["revoke", "invalidate", "timeout"], "late success after timeout cannot unlock")

        let cancelledContext = FakeContext()
        let cancelledController = AuthenticationController(makeContext: { cancelledContext })
        var cancelOrder: [String] = []
        cancelledContext.onInvalidate = { cancelOrder.append("invalidate") }
        cancelledController.authenticate(timeout: 0, willFinish: { cancelOrder.append("revoke") }) {
            cancelOrder.append(outcome($0))
        }
        cancelledController.cancel()
        check(cancelOrder == ["revoke", "invalidate"], "cancel only revokes and invalidates without completion")
        cancelledContext.respond(success: true)
        await drain()
        check(cancelOrder == ["revoke", "invalidate"], "cancelled timer and late reply cannot complete")
        cancelledController.cancel()
        check(cancelOrder.count == 2, "repeated cancellation does not revoke twice")

        let first = FakeContext()
        let second = FakeContext()
        var providerIndex = 0
        let replacementController = AuthenticationController(makeContext: {
            providerIndex += 1
            return providerIndex == 1 ? first : second
        })
        var replacementOrder: [String] = []
        first.onInvalidate = { replacementOrder.append("invalidate-old") }
        second.onInvalidate = { replacementOrder.append("invalidate-new") }
        replacementController.authenticate(timeout: 0, willFinish: { replacementOrder.append("revoke-old") }) {
            replacementOrder.append("old-" + outcome($0))
        }
        replacementController.authenticate(timeout: 60, willFinish: { replacementOrder.append("revoke-new") }) {
            replacementOrder.append("new-" + outcome($0))
        }
        check(replacementOrder == ["revoke-old", "invalidate-old"], "new attempt first cancels old attempt without completing it")
        first.respond(success: true)
        await drain()
        check(replacementOrder == ["revoke-old", "invalidate-old"], "old callback and timer cannot affect new attempt")
        second.respond(success: true)
        await drain()
        check(replacementOrder == ["revoke-old", "invalidate-old", "revoke-new", "invalidate-new", "new-success"], "new attempt completes independently")

        let unavailable = FakeContext()
        unavailable.available = false
        let unavailableController = AuthenticationController(makeContext: { unavailable })
        var unavailableOrder: [String] = []
        unavailable.onInvalidate = { unavailableOrder.append("invalidate") }
        unavailableController.authenticate(timeout: 60, willFinish: { unavailableOrder.append("revoke") }) {
            unavailableOrder.append(outcome($0))
        }
        check(unavailableOrder == ["revoke", "invalidate", "failed"], "unavailable provider also revokes before invalidation and failure")
        check(unavailable.reply == nil, "unavailable provider never evaluates authentication")

        let failure = FakeContext()
        let failureController = AuthenticationController(makeContext: { failure })
        var failureOrder: [String] = []
        failure.onInvalidate = { failureOrder.append("invalidate") }
        failureController.authenticate(timeout: 60, willFinish: { failureOrder.append("revoke") }) {
            failureOrder.append(outcome($0))
        }
        failure.respond(success: false)
        await drain()
        check(failureOrder == ["revoke", "invalidate", "failed"], "failed authentication follows same revoke/invalidate/completion ordering")
        print("SUCCESS: \(checks) authentication lifecycle assertions on the real controller; no LocalAuthentication UI")
    }
}
