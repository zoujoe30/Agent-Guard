import Foundation
import LocalAuthentication

@MainActor
final class AuthenticationController {
    enum Outcome {
        case success
        case failed(String)
        case timedOut
    }

    private var context: LAContext?
    private var attemptID: UUID?
    private var timeoutWorkItem: DispatchWorkItem?
    private var completion: ((Outcome) -> Void)?

    func authenticate(timeout: TimeInterval = 10, completion: @escaping (Outcome) -> Void) {
        cancel()

        let context = LAContext()
        context.localizedCancelTitle = "取消"

        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            completion(.failed(policyError?.localizedDescription ?? "此 Mac 无法进行身份验证"))
            return
        }

        self.context = context
        let attemptID = UUID()
        self.attemptID = attemptID
        self.completion = completion

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self, self.attemptID == attemptID else { return }
            self.context?.invalidate()
            self.finish(.timedOut)
        }
        self.timeoutWorkItem = timeoutWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "解除 Agent 托管模式"
        ) { [weak self] success, error in
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
        context?.invalidate()
        context = nil
        attemptID = nil
        completion = nil
    }

    private func finish(_ outcome: Outcome) {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        context = nil
        attemptID = nil
        let callback = completion
        completion = nil
        callback?(outcome)
    }
}
