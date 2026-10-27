import Foundation
import LocalAuthentication

/// A small adapter keeps lifecycle tests on the real controller without opening
/// system UI or replacing its finish/cancel implementation.
@MainActor
protocol AuthenticationContext: AnyObject {
    var localizedCancelTitle: String? { get set }
    func canAuthenticate(error: NSErrorPointer) -> Bool
    func evaluate(reason: String, reply: @escaping @Sendable (Bool, Error?) -> Void)
    func invalidate()
}

@MainActor
private final class SystemAuthenticationContext: AuthenticationContext {
    private let context = LAContext()
    var localizedCancelTitle: String? {
        get { context.localizedCancelTitle }
        set { context.localizedCancelTitle = newValue }
    }
    func canAuthenticate(error: NSErrorPointer) -> Bool {
        context.canEvaluatePolicy(.deviceOwnerAuthentication, error: error)
    }
    func evaluate(reason: String, reply: @escaping @Sendable (Bool, Error?) -> Void) {
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason, reply: reply)
    }
    func invalidate() { context.invalidate() }
}

@MainActor
final class AuthenticationController {
    enum Outcome {
        case success
        case failed(String)
        case timedOut
    }

    private var context: (any AuthenticationContext)?
    private let makeContext: () -> any AuthenticationContext
    private var attemptID: UUID?
    private var timeoutWorkItem: DispatchWorkItem?
    private var willFinish: (() -> Void)?
    private var completion: ((Outcome) -> Void)?

    init(makeContext: @escaping () -> any AuthenticationContext = { SystemAuthenticationContext() }) {
        self.makeContext = makeContext
    }

    func authenticate(timeout: TimeInterval = 10, willFinish: @escaping () -> Void = {}, completion: @escaping (Outcome) -> Void) {
        cancel()

        let context = makeContext()
        context.localizedCancelTitle = "取消"

        var policyError: NSError?
        guard context.canAuthenticate(error: &policyError) else {
            willFinish()
            context.invalidate()
            completion(.failed(policyError?.localizedDescription ?? "此 Mac 无法进行身份验证"))
            return
        }

        self.willFinish = willFinish
        self.context = context
        let attemptID = UUID()
        self.attemptID = attemptID
        self.completion = completion

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self, self.attemptID == attemptID else { return }
            self.finish(.timedOut)
        }
        self.timeoutWorkItem = timeoutWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

        context.evaluate(reason: "解除 Agent 托管模式") { [weak self] success, error in
            let message = error?.localizedDescription ?? "身份验证未完成"
            DispatchQueue.main.async {
                guard let self, self.attemptID == attemptID else { return }
                if success {
                    self.finish(.success)
                } else {
                    self.finish(.failed(message))
                }
            }
        }
    }

    func cancel() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        let oldContext = context
        context = nil
        attemptID = nil
        completion = nil
        let closeAllowance = willFinish
        willFinish = nil
        closeAllowance?()
        oldContext?.invalidate()
    }

    private func finish(_ outcome: Outcome) {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        let oldContext = context
        context = nil
        attemptID = nil
        let callback = completion
        completion = nil
        let closeAllowance = willFinish
        willFinish = nil
        closeAllowance?()
        oldContext?.invalidate()
        callback?(outcome)
    }
}
