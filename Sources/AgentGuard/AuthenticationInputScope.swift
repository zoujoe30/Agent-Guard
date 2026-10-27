import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Only this cache is consulted from the event-tap callback. Window enumeration
/// and the bounded AX focus lookup run on a timer, never inside that callback.
@MainActor
final class AuthenticationInputScope {
    struct Window {
        let id: UInt32
        let owner: Int32
        let bounds: CGRect
        let layer: Int
        let authentication: Bool
        let recoveryMenu: Bool
    }
    struct Snapshot {
        /// Quartz order: frontmost first. Includes non-allowed windows as blockers.
        let windows: [Window]
        let authenticationHasFocus: Bool
    }
    private enum Target: Equatable {
        case authentication(UInt32)
        case recoveryButton(UInt32)
        case recoveryMenu(UInt32)
    }
    private struct Press {
        let target: Target
        let time: TimeInterval
    }

    var recoveryMenuRegion: CGRect? {
        didSet { if oldValue != recoveryMenuRegion { presses.removeAll() } }
    }
    private let snapshotProvider: () -> Snapshot
    private let clock: () -> TimeInterval
    private let ownerPID: Int32
    private let usesTimer: Bool
    private var timer: Timer?
    private var authenticating = false
    private var recovering = false
    private var snapshot: Snapshot?
    private var capturedAt: TimeInterval = -.infinity
    private var presses: [Int: Press] = [:]
    private let maximumAge: TimeInterval = 0.30
    private let maximumPressAge: TimeInterval = 5

    init() {
        ownerPID = ProcessInfo.processInfo.processIdentifier
        snapshotProvider = { Self.captureSnapshot() }
        clock = { ProcessInfo.processInfo.systemUptime }
        usesTimer = true
    }
    /// Tests supply only synthetic windows; no event taps or authentication UI.
    init(ownerPID: Int32, clock: @escaping () -> TimeInterval,
         snapshotProvider: @escaping () -> Snapshot) {
        self.ownerPID = ownerPID
        self.clock = clock
        self.snapshotProvider = snapshotProvider
        usesTimer = false
    }

    func setMode(authenticating: Bool, recovering: Bool) {
        let changed = self.authenticating != authenticating || self.recovering != recovering
        self.authenticating = authenticating
        self.recovering = !authenticating && recovering
        guard changed else { return }
        // Invalidate permissions and paired mouse presses synchronously before
        // cancellation, UI teardown, or another authentication attempt can run.
        snapshot = nil
        capturedAt = -.infinity
        presses.removeAll()
        timer?.invalidate()
        timer = nil
        guard authenticating || recovering else { return }
        refresh()
        guard usesTimer else { return }
        let timer = Timer(timeInterval: 0.075, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.015
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Called outside the event tap, also exposed for deterministic cache tests.
    func refresh() {
        guard authenticating || recovering else { return }
        let started = clock()
        let next = snapshotProvider()
        snapshot = next
        // Count capture time against freshness; slow enumeration must not grant
        // a new full validity interval to a stale result.
        capturedAt = started
    }

    private var freshSnapshot: Snapshot? {
        let age = clock() - capturedAt
        guard age >= 0, age <= maximumAge else {
            presses.removeAll()
            return nil
        }
        return snapshot
    }

    func allowsKeyboard(targetPID: Int32) -> Bool {
        guard authenticating, let snapshot = freshSnapshot else { return false }
        return targetPID > 0 && snapshot.authenticationHasFocus
            && snapshot.windows.contains { $0.authentication && $0.owner == targetPID }
    }

    func allowsPointer(at point: CGPoint, type: CGEventType, authenticating: Bool, windowID: UInt32) -> Bool {
        guard self.authenticating || recovering,
              authenticating == self.authenticating else { return false }
        // Cursor movement alone cannot click, scroll, or begin a drag elsewhere.
        if type == .mouseMoved { return true }
        guard point.x.isFinite, point.y.isFinite, let snapshot = freshSnapshot else { return false }
        let target = target(at: point, snapshot: snapshot, eventWindowID: windowID)
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let button = Self.button(for: type)
            presses.removeValue(forKey: button)
            guard let target else { return false }
            presses[button] = Press(target: target, time: clock())
            return true
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard let press = presses.removeValue(forKey: Self.button(for: type)),
                  let target, press.target == target,
                  clock() - press.time >= 0, clock() - press.time <= maximumPressAge else { return false }
            return true
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard let press = presses[Self.button(for: type)], let target,
                  press.target == target,
                  clock() - press.time >= 0, clock() - press.time <= maximumPressAge else { return false }
            return true
        case .scrollWheel:
            return target != nil
        default:
            return false
        }
    }

    private func target(at point: CGPoint, snapshot: Snapshot, eventWindowID: UInt32) -> Target? {
        // Never search past an occluding window to find an allowed one beneath.
        guard eventWindowID != 0,
              let top = snapshot.windows.first(where: { $0.bounds.contains(point) }),
              top.id == eventWindowID else { return nil }
        if authenticating {
            return top.authentication ? .authentication(top.id) : nil
        }
        if top.owner == ownerPID && top.recoveryMenu { return .recoveryMenu(top.id) }
        if top.owner == ownerPID, let region = recoveryMenuRegion,
           region.width > 0, region.height > 0, region.contains(point) {
            return .recoveryButton(top.id)
        }
        return nil
    }

    private static func button(for type: CGEventType) -> Int {
        switch type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged: return 0
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged: return 1
        default: return 2
        }
    }

    private static let authenticationBundleID = "com.apple.LocalAuthentication.UIAgent"
    private static let authenticationExecutable = "/System/Library/Frameworks/LocalAuthentication.framework/Support/coreautha.bundle/Contents/MacOS/coreautha"

    private static func trustedAuthenticationProcess(_ pid: Int32) -> Bool {
        guard pid > 0, let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return trustedIdentity(bundleIdentifier: app.bundleIdentifier,
                               executablePath: app.executableURL?.standardizedFileURL.path)
    }

    static func trustedIdentity(bundleIdentifier: String?, executablePath: String?) -> Bool {
        bundleIdentifier == authenticationBundleID && executablePath == authenticationExecutable
    }

    static func isDialogSized(_ bounds: CGRect, displays: [CGRect]) -> Bool {
        guard !displays.isEmpty, bounds.width >= 120, bounds.height >= 60,
              bounds.width <= 900, bounds.height <= 700 else { return false }
        // Also reject a full-screen layer on a small/low-resolution display.
        return !displays.contains { display in
            let overlap = display.intersection(bounds)
            return display.width > 0 && display.height > 0 && !overlap.isNull
                && overlap.width * overlap.height >= display.width * display.height * 0.70
        }
    }

    private static func captureSnapshot() -> Snapshot {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else {
            return Snapshot(windows: [], authenticationHasFocus: false)
        }
        var displayCount: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        let displayStatus = CGGetActiveDisplayList(UInt32(displays.count), &displays, &displayCount)
        let displayBounds = displayStatus == .success
            ? displays.prefix(Int(displayCount)).map { CGDisplayBounds($0) } : []
        let pid = ProcessInfo.processInfo.processIdentifier
        let menuLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
        var trust: [Int32: Bool] = [:]
        var windows: [Window] = []
        for entry in list {
            guard (entry[kCGWindowIsOnscreen as String] as? Bool) == true,
                  let alpha = entry[kCGWindowAlpha as String] as? Double, alpha > 0.05,
                  let owner = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let identifier = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let dictionary = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  !bounds.isNull, !bounds.isInfinite, bounds.width > 0, bounds.height > 0 else { continue }
            let trusted = trust[owner] ?? trustedAuthenticationProcess(owner)
            trust[owner] = trusted
            // Reject the large authentication backdrop as a pointer target while
            // retaining it in z-order so it still prevents click-through.
            let smallDialog = Self.isDialogSized(bounds, displays: displayBounds)
            windows.append(Window(id: identifier, owner: owner, bounds: bounds, layer: layer,
                                  authentication: trusted && smallDialog,
                                  recoveryMenu: owner == pid && layer == menuLayer))
        }
        let trustedWindows = windows.filter { $0.authentication }
        guard !trustedWindows.isEmpty else {
            return Snapshot(windows: windows, authenticationHasFocus: false)
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var focusedPID = frontmost
        if frontmost.map({ trust[$0] == true }) != true {
            // AX IPC is bounded and happens here, outside the tap callback.
            let system = AXUIElementCreateSystemWide()
            _ = AXUIElementSetMessagingTimeout(system, 0.02)
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &focused) == .success,
               let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
                var candidate: pid_t = 0
                if AXUIElementGetPid(focused as! AXUIElement, &candidate) == .success { focusedPID = candidate }
            }
        }
        let focusTrusted = focusedPID.map { candidate in
            trust[candidate] == true && trustedWindows.contains { $0.owner == candidate }
        } ?? false
        return Snapshot(windows: windows, authenticationHasFocus: focusTrusted)
    }
}
