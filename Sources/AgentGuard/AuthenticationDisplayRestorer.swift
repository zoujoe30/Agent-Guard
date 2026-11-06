import CoreGraphics
import Foundation

/// A window must survive two adjacent polls on the restored built-in display.
/// This observes only trusted window metadata, never authentication controls.
struct AuthenticationDisplayGate {
    struct Window: Equatable {
        let owner: Int32
        let id: UInt32
    }
    private var previous: Window?
    private var previousTime: TimeInterval?

    mutating func observe(_ window: Window?, at now: TimeInterval) -> Bool {
        guard let window, now.isFinite else {
            previous = nil; previousTime = nil
            return false
        }
        let confirmed = previous == window && previousTime.map {
            now > $0 && now - $0 <= 0.25
        } == true
        previous = window; previousTime = now
        return confirmed
    }
}

@MainActor
final class AuthenticationDisplayRestorer {
    enum Reason: String { case dialogVisible, fallback }
    private let clock: () -> TimeInterval
    private let sampleWindow: (UInt32) -> AuthenticationDisplayGate.Window?
    private let usesTimer: Bool
    private var timer: Timer?
    private var displayID: UInt32?
    private var startedAt: TimeInterval = 0
    private var gate = AuthenticationDisplayGate()
    private var completion: ((Reason) -> Void)?
    private(set) var generation: UInt64 = 0

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sampleWindow: @escaping (UInt32) -> AuthenticationDisplayGate.Window? = { AuthenticationDisplayRestorer.captureWindow(on: $0) },
         usesTimer: Bool = true) {
        self.clock = clock; self.sampleWindow = sampleWindow; self.usesTimer = usesTimer
    }

    func start(builtInDisplayID: UInt32, completion: @escaping (Reason) -> Void) {
        cancel()
        displayID = builtInDisplayID; startedAt = clock(); self.completion = completion
        guard usesTimer else { return }
        let expected = generation
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll(generation: expected) }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func cancel() {
        generation &+= 1
        timer?.invalidate(); timer = nil
        completion = nil; displayID = nil; gate = AuthenticationDisplayGate()
    }

    /// Explicit generation also protects against an already-enqueued old tick.
    func poll(generation expected: UInt64) {
        guard expected == generation, let id = displayID, completion != nil else { return }
        let now = clock()
        let window = sampleWindow(id)
        // Sampling can perform bounded AX IPC; recheck after it returns.
        guard expected == generation, completion != nil else { return }
        let reason: Reason?
        if gate.observe(window, at: now) { reason = .dialogVisible }
        else if clock() - startedAt >= 1.5 { reason = .fallback }
        else { reason = nil }
        guard let reason else { return }
        let callback = completion
        cancel() // one-shot and revoke before running display configuration code
        callback?(reason)
    }

    private static func captureWindow(on display: UInt32) -> AuthenticationDisplayGate.Window? {
        guard CGDisplayIsBuiltin(display) != 0, CGDisplayIsActive(display) != 0 else { return nil }
        var ids = [UInt32](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(32, &ids, &count) == .success,
              count == 1, ids[0] == display else { return nil }
        let screen = CGDisplayBounds(display)
        let snapshot = AuthenticationInputScope.captureSnapshot()
        guard snapshot.authenticationHasFocus else { return nil }
        guard let window = snapshot.windows.first(where: { w in
            guard w.authentication else { return false }
            let overlap = screen.intersection(w.bounds)
            return !overlap.isNull && overlap.width * overlap.height >= w.bounds.width * w.bounds.height * 0.95
        }) else { return nil }
        return .init(owner: window.owner, id: window.id)
    }
}
