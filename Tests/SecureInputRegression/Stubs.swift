import Foundation
import AgentGuardCore

@MainActor let NSApp = TestApplication()
@MainActor final class TestApplication {
    func activate(ignoringOtherApps: Bool) {}
}
@MainActor final class InputBlocker {
    static var healthy = true
    static var installCount = 0
    static var onInstall: (() -> Void)?
    static var failure: (() -> Void)?
    func installIfNeeded(spaceHandler: @escaping () -> Void, activationShortcutHandler: @escaping () -> Void, displayShortcutHandler: @escaping () -> Void, failureHandler: @escaping () -> Void) -> Bool {
        Self.installCount += 1
        Self.onInstall?()
        Self.failure = failureHandler
        return Self.healthy
    }
    func setState(_ state: GuardState) {}
}
@MainActor final class AuthenticationController {
    enum Outcome { case success, failed(String), timedOut }
    static var pending: ((Outcome) -> Void)?
    static var count = 0
    func authenticate(timeout: TimeInterval, completion: @escaping (Outcome) -> Void) {
        Self.count += 1
        Self.pending = completion
    }
    func cancel() { Self.pending = nil }
    static func finish(_ outcome: Outcome) {
        let callback = pending
        pending = nil
        callback?(outcome)
    }
}
@MainActor final class PowerAssertionController {
    static var applyCount = 0
    static var onApply: (() -> Void)?
    func apply(_ policy: PowerPolicy) -> String? { Self.applyCount += 1; Self.onApply?(); return nil }
    func release() {}
}
@MainActor final class DisplayBlackoutController {
    static var healthFailure: String?
    static var restoreFailure: String?
    func healthError() -> String? { Self.healthFailure }
    static var blackoutCount = 0
    static var restoreCount = 0
    func blackOutDisplays() -> String? { Self.blackoutCount += 1; return nil }
    func restoreDisplays() -> String? { Self.restoreCount += 1; return Self.restoreFailure }
}

@MainActor final class KeyboardBacklightController {
    static var offError: String?
    static var offCount = 0
    static var restoreCount = 0
    static var healthError: String?
    static var restoreError: String?
    func turnOff() -> String? { Self.offCount += 1; return Self.offError }
    func restore() -> String? { Self.restoreCount += 1; return Self.restoreError }
    func keepOff() -> String? { Self.healthError }
}
