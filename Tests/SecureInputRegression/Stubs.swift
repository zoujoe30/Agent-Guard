import Foundation
import CoreGraphics
import AgentGuardCore

@MainActor let NSApp = TestApplication()
@MainActor final class TestApplication {
    func activate(ignoringOtherApps: Bool) {}
}
@MainActor final class InputBlocker {
    var recoveryMenuRegion: CGRect?
    static var lastState: GuardState = .inactive
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
    func setState(_ state: GuardState) { Self.lastState = state }
}
@MainActor final class AuthenticationController {
    enum Outcome { case success, failed(String), timedOut }
    static var willFinish: (() -> Void)?
    static var pending: ((Outcome) -> Void)?
    static var count = 0
    func authenticate(timeout: TimeInterval, willFinish: @escaping () -> Void, completion: @escaping (Outcome) -> Void) {
        Self.count += 1
        Self.willFinish = willFinish
        Self.pending = completion
    }
    func cancel() { Self.pending = nil; Self.willFinish?(); Self.willFinish = nil }
    static func finish(_ outcome: Outcome) {
        let callback = pending
        pending = nil
        willFinish?()
        willFinish = nil
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

@MainActor final class DisplayRecoveryJournal {
    static let defaultURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agentguard-display-test-" + UUID().uuidString + "/record.json")
}

@MainActor final class KeyboardBacklightController {
    static let journalURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agentguard-keyboard-test-" + UUID().uuidString + "/record.json")
    static var offError: String?
    static var offCount = 0
    static var restoreCount = 0
    static var healthError: String?
    static var restoreError: String?
    func turnOff() -> String? { Self.offCount += 1; return Self.offError }
    func restore() -> String? { Self.restoreCount += 1; return Self.restoreError }
    func keepOff() -> String? { Self.healthError }
}
