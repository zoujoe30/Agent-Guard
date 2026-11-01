import CoreGraphics
import Foundation

@MainActor final class AuthenticationInputScope {
    var recoveryMenuRegion: CGRect?
    var allowPointer = false
    var allowKeyboard = false
    var allowPointerRouting = false
    func mayRoutePointer(at: CGPoint, type: CGEventType, authenticating: Bool,
                         observedWindowID: UInt32 = 0, handlingWindowID: UInt32 = 0) -> Bool { allowPointerRouting }
    func setMode(authenticating: Bool, recovering: Bool) {}
    func allowsPointer(at: CGPoint, type: CGEventType, authenticating: Bool, windowID: UInt32) -> Bool { allowPointer }
    func allowsKeyboard(targetPID: Int32) -> Bool { allowKeyboard }
}


@main struct InputRegression {
    @MainActor static func main() async {
        let blocker = InputBlocker()
        var checks = 0
        func check(_ ok: Bool, _ name: String) {
            guard ok else { fatalError("FAIL: \(name)") }
            checks += 1
            print("PASS: \(name)")
        }
        func drop(_ type: CGEventType, _ pid: Int64) -> Bool {
            blocker.shouldDrop(type: type, sourcePID: pid, keyCode: 0, isRepeat: false, modifierFlagsRawValue: 0, hasOtherModifiers: false)
        }
        blocker.setState(.recoveryFailed)
        for event: CGEventType in [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .scrollWheel, .keyDown, .keyUp] {
            check(drop(event, 0), "physical event \(event.rawValue) blocked in recovery")
            check(drop(event, 4321), "synthetic event \(event.rawValue) blocked in recovery")
        }
        var spaces = 0
        blocker.spaceHandler = { spaces += 1 }
        for event: CGEventType in [.keyDown, .keyUp] {
            for isRepeat in [false, true] {
                for modifiers: UInt64 in [0, CGEventFlags.maskCommand.rawValue, CGEventFlags.maskShift.rawValue] {
                    check(blocker.shouldDrop(type:event,sourcePID:0,keyCode:49,isRepeat:isRepeat,modifierFlagsRawValue:modifiers,hasOtherModifiers:modifiers != 0), "physical recovery Space consumed type=\(event.rawValue) repeat=\(isRepeat) modifiers=\(modifiers)")
                    check(blocker.shouldDrop(type:event,sourcePID:4321,keyCode:49,isRepeat:isRepeat,modifierFlagsRawValue:modifiers,hasOtherModifiers:modifiers != 0), "synthetic recovery Space blocked type=\(event.rawValue) repeat=\(isRepeat) modifiers=\(modifiers)")
                }
            }
        }
        await Task.yield()
        check(spaces == 3, "nonrepeated recovery Space invokes authentication while consuming key")
        spaces = 0
        blocker.setState(.guarding)
        check(drop(.leftMouseDown, 0), "normal guarding still blocks physical mouse")
        check(!drop(.leftMouseDown, 4321), "normal guarding still allows agent input")
        check(blocker.shouldDrop(type:.keyDown,sourcePID:0,keyCode:49,isRepeat:false,modifierFlagsRawValue:0,hasOtherModifiers:false), "normal guarding consumes physical Space")
        check(blocker.shouldDrop(type:.keyDown,sourcePID:0,keyCode:49,isRepeat:true,modifierFlagsRawValue:0,hasOtherModifiers:false), "normal guarding consumes repeated physical Space")
        check(!blocker.shouldDrop(type:.keyDown,sourcePID:4321,keyCode:49,isRepeat:false,modifierFlagsRawValue:0,hasOtherModifiers:false), "normal guarding allows synthetic Space")
        await Task.yield()
        check(spaces == 1, "normal guarding invokes authentication once for physical Space")
        blocker.setState(.authenticating)
        check(drop(.leftMouseDown, 0), "authentication blocks mouse outside validated dialog")
        blocker.inputScope.allowPointer = true
        check(!drop(.leftMouseDown, 0), "authentication permits explicitly validated dialog pointer")
        blocker.inputScope.allowPointer = false
        check(drop(.keyDown, 0), "authentication blocks keyboard when trusted focus unknown")
        blocker.inputScope.allowKeyboard = true
        check(!drop(.keyDown, 0), "authentication permits keyboard only with trusted focus")
        blocker.setState(.restoringInput)
        check(drop(.leftMouseDown, 0) && drop(.leftMouseDown, 4321), "authentication teardown blocks physical and agent pointer")
        blocker.setState(.authenticating)
        check(drop(.leftMouseDown, 4321), "authentication blocks synthetic mouse")
        // Actual event policy, without creating an event tap or injecting input.
        let shortcut = InputBlocker()
        var activations = 0
        var toggles = 0
        shortcut.activationShortcutHandler = { activations += 1 }
        shortcut.displayShortcutHandler = { toggles += 1 }
        let right: UInt64 = CGEventFlags.maskCommand.rawValue | 0x10
        func key(_ type: CGEventType, _ code: Int64, _ flags: UInt64? = nil,
                 pid: Int64 = 0, repeatKey: Bool = false, other: Bool = false) -> Bool {
            shortcut.shouldDrop(type: type, sourcePID: pid, keyCode: code,
                isRepeat: repeatKey, modifierFlagsRawValue: flags ?? right,
                hasOtherModifiers: other)
        }
        check(key(.keyDown, 5), "G prefix consumed")
        await Task.yield()
        check(activations == 0, "G down waits for chord completion")
        check(key(.keyDown, 1), "S chord consumed")
        check(key(.keyDown, 1, repeatKey: true), "S repeat consumed")
        check(key(.keyDown, 5, repeatKey: true), "G repeat consumed")
        await Task.yield()
        check(toggles == 1 && activations == 0, "display chord toggles exactly once without activating")
        check(key(.keyUp, 1), "S release consumed")
        check(key(.keyUp, 5), "G release after S consumed")
        check(!key(.flagsChanged, 54, 0), "right Command release remains paired")
        await Task.yield()
        check(activations == 0, "display chord release cannot activate")
        check(key(.keyDown, 5), "short activation prefix consumed")
        check(key(.keyUp, 5), "short activation release consumed")
        await Task.yield()
        check(activations == 1 && toggles == 1, "G alone activates on release")
        _ = key(.flagsChanged, 54, 0)
        _ = key(.keyDown, 5)
        check(!key(.flagsChanged, 54, 0), "Command-first release passes")
        _ = key(.keyUp, 5, 0)
        await Task.yield()
        check(activations == 2, "Command-first release activates once")
        for state: GuardState in [.guarding, .authenticating, .restoringInput, .recoveryFailed] {
            shortcut.setState(state)
            _ = key(.keyDown, 5); _ = key(.keyDown, 1)
            _ = key(.keyUp, 1); _ = key(.keyUp, 5)
            _ = key(.flagsChanged, 54, 0)
            await Task.yield()
            check(toggles == 1 && activations == 2, "shortcuts disabled in \(state)")
        }
        shortcut.setState(.inactive)
        check(!key(.keyDown, 5, pid: 4321), "synthetic G is not a prefix")
        check(!key(.keyDown, 1, pid: 4321), "synthetic S cannot toggle")
        _ = key(.keyUp, 5, pid: 4321)
        for flags: UInt64 in [0, CGEventFlags.maskCommand.rawValue | 0x08, right | 0x08] {
            check(!key(.keyDown, 5, flags), "only right Command starts prefix flags=\(flags)")
            _ = key(.keyDown, 1, flags); _ = key(.keyUp, 5, flags)
        }
        check(!key(.keyDown, 5, other: true), "extra modifier rejects prefix")
        _ = key(.keyDown, 5)
        check(!key(.keyDown, 1, pid: 4321), "synthetic S cannot complete physical prefix")
        check(!key(.keyUp, 5, pid: 4321), "synthetic release cannot finish physical prefix")
        _ = key(.flagsChanged, 56, right, other: true)
        _ = key(.keyUp, 5)
        await Task.yield()
        check(toggles == 1 && activations == 2, "extra modifier cancels physical prefix")
        _ = key(.keyDown, 5)
        check(!key(.keyDown, 0), "unrelated key passes and cancels prefix")
        _ = key(.keyUp, 5)
        await Task.yield()
        check(activations == 2, "unrelated chord does not accidentally activate")
        _ = key(.keyDown, 5); _ = key(.keyDown, 1)
        shortcut.setState(.guarding)
        await Task.yield()
        check(toggles == 1, "queued toggle canceled if guarding starts")
        _ = key(.keyUp, 1); _ = key(.keyUp, 5)
        shortcut.setState(.inactive)
        _ = key(.keyDown, 5); _ = key(.keyUp, 5)
        shortcut.setState(.authenticating); shortcut.setState(.inactive)
        await Task.yield()
        check(activations == 2, "queued activation invalid across state transitions")
        _ = key(.keyDown, 5); _ = key(.keyDown, 1)
        shortcut.invalidate()
        await Task.yield()
        check(toggles == 1, "tap invalidation cancels queued toggle")
        // Execute both production stages in order, without native event taps.
        let pair = InputBlocker()
        pair.setState(.guarding)
        var pairSpaces = 0
        pair.spaceHandler = { pairSpaces += 1 }
        func stage(_ whereAt: InputBlocker.Stage, _ type: CGEventType,
                   pid: Int64 = 0, code: Int64 = 0, flags: UInt64 = 0,
                   repeated: Bool = false) -> Bool {
            pair.shouldDrop(type: type, sourcePID: pid, keyCode: code,
                isRepeat: repeated, modifierFlagsRawValue: flags,
                hasOtherModifiers: false, stage: whereAt)
        }
        func pipeline(_ type: CGEventType, code: Int64 = 0, flags: UInt64 = 0) -> Bool {
            if stage(.session, type, code: code, flags: flags) { return true }
            return stage(.annotated, type, code: code, flags: flags)
        }
        for type: CGEventType in [.mouseMoved, .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel, .tabletPointer, .tabletProximity] {
            check(stage(.session, type), "physical pointer blocked before annotation type=\(type.rawValue)")
            check(!stage(.session, type, pid: 4321) && !stage(.annotated, type, pid: 4321),
                  "agent pointer crosses both guarding stages type=\(type.rawValue)")
        }
        check(pipeline(.keyDown, code: 49), "physical Space consumed in two-stage pipeline")
        check(stage(.session, .keyDown, code: 49, repeated: true), "repeated Space consumed early")
        await Task.yield()
        check(pairSpaces == 1, "two-stage pipeline requests authentication once per Space")
        check(!stage(.session, .keyDown, pid: 4321, code: 49)
              && !stage(.annotated, .keyDown, pid: 4321, code: 49),
              "synthetic Space passes both stages without authenticating")
        await Task.yield()
        check(pairSpaces == 1, "synthetic Space cannot request authentication")
        pair.setState(.inactive)
        check(!stage(.session, .leftMouseDown), "inactive session stage passes physical input")
        pair.setState(.guarding)
        check(stage(.annotated, .leftMouseDown), "late guard blocks event admitted before activation")
        for mode: GuardState in [.authenticating, .restoringInput, .recoveryFailed] {
            pair.setState(mode)
            pair.inputScope.allowPointer = false
            pair.inputScope.allowKeyboard = false
            pair.inputScope.allowPointerRouting = false
            check(stage(.session, .leftMouseDown) && stage(.annotated, .leftMouseDown),
                  "\(mode) pointer outside candidate is rejected before annotation")
            check(stage(.session, .keyDown) == (mode != .authenticating) && stage(.annotated, .keyDown),
                  "\(mode) keyboard retains late authentication target or early recovery block")
            check(stage(.session, .leftMouseDown, pid: 4321)
                  && stage(.annotated, .leftMouseDown, pid: 4321),
                  "\(mode) still rejects agent input")
            pair.inputScope.allowPointerRouting = true
            check(!stage(.session, .leftMouseDown) && stage(.annotated, .leftMouseDown),
                  "\(mode) candidate routing alone cannot authorize late input")
            pair.inputScope.allowPointer = true
            check(!stage(.session, .leftMouseDown) && !stage(.annotated, .leftMouseDown),
                  "\(mode) validated pointer is not consumed twice")
        }
        for mode: GuardState in [.restoringInput, .recoveryFailed] {
            pair.setState(mode)
            let before = pairSpaces
            check(pipeline(.keyDown, code: 49), "\(mode) consumes Space at early stage")
            await Task.yield()
            check(pairSpaces == before + 1, "\(mode) requests authentication only once")
        }
        pair.setState(.inactive)
        var pairActivations = 0
        var pairToggles = 0
        pair.activationShortcutHandler = { pairActivations += 1 }
        pair.displayShortcutHandler = { pairToggles += 1 }
        check(pipeline(.keyDown, code: 5, flags: right), "two-stage G prefix consumed once")
        check(pipeline(.keyUp, code: 5, flags: right), "two-stage G release consumed once")
        await Task.yield()
        check(pairActivations == 1, "two-stage G activates once")
        pair.setState(.guarding)
        check(!stage(.session, .flagsChanged, code: 54), "early stage preserves pending Command release")
        check(!stage(.annotated, .flagsChanged, code: 54), "late stage passes paired Command release")
        check(stage(.session, .flagsChanged, code: 54), "Command release exception cannot be reused")
        pair.setState(.inactive)
        _ = pipeline(.keyDown, code: 5, flags: right)
        _ = pipeline(.keyDown, code: 1, flags: right)
        _ = pipeline(.keyUp, code: 1, flags: right)
        _ = pipeline(.keyUp, code: 5, flags: right)
        _ = pipeline(.flagsChanged, code: 54)
        await Task.yield()
        check(pairToggles == 1 && pairActivations == 1, "two-stage display chord toggles once without activation")
        print("SUCCESS: \(checks) input policy assertions; no event tap or injected input")
    }
}
