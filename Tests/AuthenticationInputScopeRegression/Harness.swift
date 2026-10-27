import AppKit
import CoreGraphics
import Foundation

@main struct ScopeRegression {
    @MainActor static func main() {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            guard value() else { fatalError("FAIL: \(name)") }
            count += 1
            print("PASS: \(name)")
        }
        let systemPath = "/System/Library/Frameworks/LocalAuthentication.framework/Support/coreautha.bundle/Contents/MacOS/coreautha"
        check(AuthenticationInputScope.trustedIdentity(bundleIdentifier: "com.apple.LocalAuthentication.UIAgent", executablePath: systemPath), "exact system authentication identity accepted")
        check(!AuthenticationInputScope.trustedIdentity(bundleIdentifier: "com.apple.LocalAuthentication.UIAgent", executablePath: "/tmp/coreautha"), "matching bundle ID with another executable rejected")
        check(!AuthenticationInputScope.trustedIdentity(bundleIdentifier: "spoof", executablePath: systemPath), "matching executable with another bundle ID rejected")
        check(!AuthenticationInputScope.trustedIdentity(bundleIdentifier: nil, executablePath: nil), "unknown process identity rejected")
        typealias Window = AuthenticationInputScope.Window
        let auth = Window(id: 1, owner: 500, bounds: CGRect(x: 100, y: 100, width: 400, height: 200), layer: 100,
                          authentication: true, recoveryMenu: false)
        let desktop = Window(id: 2, owner: 999, bounds: CGRect(x: 0, y: 0, width: 2000, height: 1000), layer: 0,
                             authentication: false, recoveryMenu: false)
        check(AuthenticationInputScope.isDialogSized(auth.bounds, displays: [desktop.bounds]), "ordinary small dialog accepted")
        check(!AuthenticationInputScope.isDialogSized(CGRect(x: 0, y: 0, width: 800, height: 600),
              displays: [CGRect(x: 0, y: 0, width: 800, height: 600)]), "small full-screen backdrop rejected")
        check(!AuthenticationInputScope.isDialogSized(auth.bounds, displays: []), "unknown display geometry denies dialog")
        var now: TimeInterval = 10
        var windows = [auth, desktop]
        var focused = true
        var queries = 0
        let scope = AuthenticationInputScope(ownerPID: 42, clock: { now }, snapshotProvider: {
            queries += 1
            return AuthenticationInputScope.Snapshot(windows: windows, authenticationHasFocus: focused)
        })
        let inside = CGPoint(x: 120, y: 140)
        let outside = CGPoint(x: 700, y: 400)
        func allow(_ type: CGEventType, _ point: CGPoint = CGPoint(x: 120, y: 140), auth: Bool = true, eventWindow: UInt32? = nil) -> Bool {
            scope.allowsPointer(at: point, type: type, authenticating: auth,
                                windowID: eventWindow ?? windows.first(where: { $0.bounds.contains(point) })?.id ?? 0)
        }
        check(!scope.allowsKeyboard(targetPID: 500), "inactive keyboard denied")
        check(!allow(.leftMouseDown), "inactive pointer denied")
        scope.setMode(authenticating: true, recovering: false)
        check(scope.allowsKeyboard(targetPID: 500), "trusted focused authentication permits keyboard")
        check(!scope.allowsKeyboard(targetPID: 0), "unknown actual keyboard target denied")
        check(!scope.allowsKeyboard(targetPID: 999), "stale focus cannot authorize another keyboard target")
        check(allow(.mouseMoved, outside), "pointer may move outside dialog")
        check(!allow(.leftMouseDown, outside), "outside click denied")
        check(!allow(.scrollWheel, outside), "outside scroll denied")
        check(allow(.scrollWheel, inside), "inside scroll permitted")
        check(!allow(.leftMouseDown, inside, eventWindow: 0), "unannotated event never gains pointer access")
        check(!allow(.leftMouseDown, inside, eventWindow: 2), "disappeared panel cannot authorize its cached rectangle")
        check(!allow(.leftMouseDown, inside, eventWindow: 3), "different actual event window cannot use cached permission")
        check(!allow(.leftMouseUp), "unpaired mouse up denied")
        check(!allow(.leftMouseDragged), "unpaired drag denied")
        check(allow(.leftMouseDown), "inside press permitted")
        check(allow(.leftMouseDragged), "paired inside drag permitted")
        check(!allow(.leftMouseDragged, outside), "drag outside denied")
        check(!allow(.rightMouseUp), "mismatched button release denied")
        check(allow(.leftMouseUp), "matching inside release permitted")
        check(!allow(.leftMouseUp), "release cannot be reused")
        check(queries == 1, "pointer and keyboard predicates never enumerate windows")
        focused = false
        scope.refresh()
        check(!scope.allowsKeyboard(targetPID: 500), "unknown focus denies keyboard")
        focused = true
        let cover = Window(id: 3, owner: 888, bounds: auth.bounds, layer: 200, authentication: false, recoveryMenu: false)
        windows = [cover, auth, desktop]
        scope.refresh()
        check(!allow(.leftMouseDown), "foreground overlay prevents click-through")
        windows = [auth, desktop]
        scope.refresh()
        check(allow(.leftMouseDown), "new valid press permitted")
        windows = [desktop]
        scope.refresh()
        check(!allow(.leftMouseUp), "disappeared panel receives no release")
        check(!scope.allowsKeyboard(targetPID: 500), "no authentication windows denies keyboard")
        windows = [auth, desktop]
        scope.refresh()
        check(allow(.leftMouseDown), "press before expiry permitted")
        now += 0.31
        check(!scope.allowsKeyboard(targetPID: 500), "expired snapshot denies keyboard")
        check(!allow(.leftMouseUp), "expired snapshot denies release")
        scope.refresh()
        check(!allow(.leftMouseUp), "expired press is not resurrected by refresh")
        check(!allow(.leftMouseDown, auth: false), "caller mode mismatch denied")
        check(allow(.leftMouseDown), "press before exit permitted")
        scope.setMode(authenticating: false, recovering: true)
        check(!scope.allowsKeyboard(targetPID: 500), "recovery keyboard denied")
        check(!allow(.leftMouseUp, auth: false), "mode change clears prior press")
        let button = Window(id: 10, owner: 42, bounds: CGRect(x: 800, y: 0, width: 30, height: 24), layer: 25,
                            authentication: false, recoveryMenu: false)
        let menu = Window(id: 11, owner: 42, bounds: CGRect(x: 600, y: 24, width: 230, height: 300), layer: 101,
                          authentication: false, recoveryMenu: true)
        windows = [button, menu, desktop]
        scope.recoveryMenuRegion = button.bounds
        scope.refresh()
        let buttonPoint = CGPoint(x: 810, y: 12)
        let menuPoint = CGPoint(x: 700, y: 80)
        check(allow(.leftMouseDown, buttonPoint, auth: false), "exact recovery status button allowed")
        check(allow(.leftMouseUp, buttonPoint, auth: false), "recovery button paired release allowed")
        check(allow(.leftMouseDown, menuPoint, auth: false), "own popup menu allowed")
        check(allow(.leftMouseUp, menuPoint, auth: false), "own menu release allowed")
        check(!allow(.leftMouseDown, outside, auth: false), "recovery desktop click denied")
        scope.recoveryMenuRegion = CGRect(x: 0, y: 0, width: 2000, height: 1000)
        check(!allow(.leftMouseDown, outside, auth: false), "passed region never permits another process")
        windows = [cover, button, menu, desktop]
        scope.recoveryMenuRegion = auth.bounds
        scope.refresh()
        check(!allow(.leftMouseDown, inside, auth: false), "overlay cannot exploit recovery rectangle")
        scope.setMode(authenticating: false, recovering: false)
        check(!scope.allowsKeyboard(targetPID: 500), "ending scope clears keyboard permission immediately")
        check(!allow(.leftMouseDown, buttonPoint, auth: false), "ending scope clears pointer permission immediately")
        print("SUCCESS: \(count) authentication input scope assertions; no event tap, input injection or authentication UI")
    }
}
