import AppKit
import Foundation
import OSLog

/// Display reconfiguration can deactivate coreautha while its dialog remains
/// visible. Restore only the exact, previously-focused native authentication
/// session, once, during a bounded post-reconnection interval.
@MainActor
final class AuthenticationFocusRestorer {
    struct Observation {
        let window: AuthenticationDisplayGate.Window?
        let hasFocus: Bool
    }
    private let clock: () -> TimeInterval
    private let observe: () -> Observation
    private let activate: (AuthenticationDisplayGate.Window) -> Bool
    private let usesTimer: Bool
    private var timer: Timer?
    private var target: AuthenticationDisplayGate.Window?
    private var deadline: TimeInterval?
    private var requested = false
    private(set) var generation: UInt64 = 0
    private let logger = Logger(subsystem: "com.local.agentguard", category: "AuthenticationFocus")

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         observe: @escaping () -> Observation = { AuthenticationFocusRestorer.capture() },
         activate: @escaping (AuthenticationDisplayGate.Window) -> Bool = { AuthenticationFocusRestorer.activateNative($0) },
         usesTimer: Bool = true) {
        self.clock = clock; self.observe = observe; self.activate = activate; self.usesTimer = usesTimer
    }

    func prepareForDisplayRecovery() {
        cancel()
        let expected = generation
        let before = observe()
        guard expected == generation, before.hasFocus else { return }
        target = before.window
    }

    func displayRecoveryCompleted() {
        guard target != nil else { return }
        deadline = clock() + 1.5
        let expected = generation
        if usesTimer {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll(generation: expected) }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        poll(generation: expected)
    }

    func cancel() {
        generation &+= 1
        timer?.invalidate(); timer = nil
        target = nil; deadline = nil; requested = false
    }

    func poll(generation expected: UInt64) {
        guard expected == generation, let target, let deadline else { return }
        guard clock() < deadline else { cancel(); return }
        let current = observe()
        guard expected == generation else { return }
        guard current.window == target, clock() < deadline else { cancel(); return }
        if current.hasFocus {
            if requested { cancel() }
            return // topology can steal focus after the configure call returns
        }
        guard !requested else { return }
        requested = true
        let accepted = activate(target)
        logger.notice("Native authentication focus request accepted: \(accepted)")
        // Acceptance is not proof of actual focus; subsequent observations and
        // the unchanged InputBlocker continue to use real focus information.
    }

    private static func capture() -> Observation {
        let snapshot = AuthenticationInputScope.captureSnapshot()
        let windows = snapshot.windows.filter(\.authentication)
        guard windows.count == 1, let window = windows.first else {
            return Observation(window: nil, hasFocus: false)
        }
        return Observation(window: .init(owner: window.owner, id: window.id), hasFocus: snapshot.authenticationHasFocus)
    }

    private static func activateNative(_ target: AuthenticationDisplayGate.Window) -> Bool {
        let current = capture()
        guard current.window == target, !current.hasFocus,
              let app = NSRunningApplication(processIdentifier: target.owner),
              AuthenticationInputScope.trustedIdentity(bundleIdentifier: app.bundleIdentifier,
                                                      executablePath: app.executableURL?.standardizedFileURL.path) else { return false }
        return app.activate(options: [])
    }
}
