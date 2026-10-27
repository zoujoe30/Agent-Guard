import CoreGraphics
import Foundation

@MainActor final class AuthenticationInputScope {
    var recoveryMenuRegion: CGRect?
    var allowPointer = false
    var allowKeyboard = false
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
        print("SUCCESS: \(checks) input policy assertions; no event tap or injected input")
    }
}
