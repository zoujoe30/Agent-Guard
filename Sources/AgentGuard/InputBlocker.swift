import AppKit
import AgentGuardCore
import CoreGraphics
import Foundation
import OSLog

@MainActor
final class InputBlocker: EventTapDriver {
    typealias SpaceHandler = @MainActor () -> Void
    typealias ActivationShortcutHandler = @MainActor () -> Void

    private(set) var state: GuardState = .inactive
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var spaceHandler: SpaceHandler?
    private var activationShortcutHandler: ActivationShortcutHandler?
    private var shouldPassRightCommandRelease = false
    private var displayShortcutHandler: ActivationShortcutHandler?
    private var pendingActivation = false
    private var consumedShortcutKeys: Set<Int64> = []
    private var shortcutGeneration: UInt64 = 0
    private var failureHandler: (@MainActor () -> Void)?
    private var generation: UInt64 = 0
    private let logger = Logger(subsystem: "com.local.agentguard", category: "InputHealth")

    func installIfNeeded(
        spaceHandler: @escaping SpaceHandler,
        activationShortcutHandler: @escaping ActivationShortcutHandler,
        displayShortcutHandler: @escaping ActivationShortcutHandler,
        failureHandler: @escaping @MainActor () -> Void
    ) -> Bool {
        self.spaceHandler = spaceHandler
        self.activationShortcutHandler = activationShortcutHandler
        self.displayShortcutHandler = displayShortcutHandler
        self.failureHandler = failureHandler
        let healthy = EventTapRecovery.ensureHealthy(self)
        if !healthy { logger.error("Input tap installation/recovery failed") }
        return healthy
    }

    var isValid: Bool {
        guard let eventTap, let runLoopSource else { return false }
        return CFMachPortIsValid(eventTap) && CFRunLoopSourceIsValid(runLoopSource)
    }

    var isEnabled: Bool {
        guard isValid, let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    func enable() {
        guard isValid, let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        logger.notice("Input tap enable read-back: \(self.isEnabled)")
    }

    func invalidate() {
        generation &+= 1
        if let eventTap, CFMachPortIsValid(eventTap) {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        runLoopSource = nil
        eventTap = nil
        shouldPassRightCommandRelease = false
        pendingActivation = false
        consumedShortcutKeys.removeAll()
        shortcutGeneration &+= 1
    }

    func create() -> Bool {
        let mask = Self.eventMask
        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: opaqueSelf
        ) else {
            logger.error("Input tap creation failed")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            logger.error("Input tap run-loop source creation failed")
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        eventTap = tap
        runLoopSource = source
        logger.notice("Input tap created")
        return true
    }

    func setState(_ state: GuardState) {
        if self.state != state {
            pendingActivation = false
            shortcutGeneration &+= 1
        }
        self.state = state
    }

    private nonisolated static let eventTapCallback: CGEventTapCallBack = {
        _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let blocker = Unmanaged<InputBlocker>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MainActor.assumeIsolated {
                let generation = blocker.generation
                blocker.logger.error("Input tap disabled: event type \(type.rawValue)")
                // Rebuild after leaving the callback, and ignore work queued by
                // a listener that has since been replaced.
                Task { @MainActor [weak blocker] in
                    guard let blocker, blocker.generation == generation else { return }
                    if !EventTapRecovery.ensureHealthy(blocker) {
                        blocker.logger.fault("Input tap recovery failed; input protection unavailable")
                        blocker.failureHandler?()
                    }
                }
            }
            return Unmanaged.passUnretained(event)
        }

        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let flags = event.flags
        let otherModifierMask: CGEventFlags = [
            .maskShift,
            .maskControl,
            .maskAlternate,
            .maskSecondaryFn
        ]
        let hasOtherModifiers = !flags.intersection(otherModifierMask).isEmpty

        let shouldDrop = MainActor.assumeIsolated {
            blocker.shouldDrop(
                type: type,
                sourcePID: sourcePID,
                keyCode: keyCode,
                isRepeat: isRepeat,
                modifierFlagsRawValue: flags.rawValue,
                hasOtherModifiers: hasOtherModifiers
            )
        }
        return shouldDrop ? nil : Unmanaged.passUnretained(event)
    }

    private func shouldDrop(
        type: CGEventType,
        sourcePID: Int64,
        keyCode: Int64,
        isRepeat: Bool,
        modifierFlagsRawValue: UInt64,
        hasOtherModifiers: Bool
    ) -> Bool {
        let isRightCommandPressed = ActivationShortcutMatcher.isRightCommandPressed(
            modifierFlagsRawValue: modifierFlagsRawValue
        )
        if EventOriginClassifier.isPhysical(sourcePID: sourcePID),
           shouldPassRightCommandRelease,
           type == .flagsChanged,
           keyCode == Self.rightCommandKeyCode,
           !isRightCommandPressed {
            shouldPassRightCommandRelease = false
            if pendingActivation {
                pendingActivation = false
                queueShortcut(activate: true)
            }
            return false
        }

        // Only physical input can build or finish a shortcut. Consume the
        // matching key-up even if a state transition happened after key-down.
        let physical = EventOriginClassifier.isPhysical(sourcePID: sourcePID)
        if physical, type == .keyUp, consumedShortcutKeys.remove(keyCode) != nil {
            if keyCode == ActivationShortcutMatcher.gKeyCode, pendingActivation {
                pendingActivation = false
                queueShortcut(activate: true)
            }
            return true
        }
        if physical, type == .keyDown, consumedShortcutKeys.contains(keyCode) {
            return true // auto-repeat must never retrigger either shortcut
        }

        switch state {
        case .inactive:
            guard physical else { return false }
            if type == .keyDown,
               ActivationShortcutMatcher.matches(
                   sourcePID: sourcePID,
                   keyCode: keyCode,
                   isRepeat: isRepeat,
                   modifierFlagsRawValue: modifierFlagsRawValue,
                   hasOtherModifiers: hasOtherModifiers
               ) {
                pendingActivation = true
                consumedShortcutKeys.insert(keyCode)
                shouldPassRightCommandRelease = true
                return true
            }
            if pendingActivation, type == .keyDown, keyCode == Self.sKeyCode,
               !isRepeat, isRightCommandPressed,
               modifierFlagsRawValue & ActivationShortcutMatcher.leftCommandDeviceFlag == 0,
               !hasOtherModifiers {
                pendingActivation = false
                consumedShortcutKeys.insert(keyCode)
                queueShortcut(activate: false)
                return true
            }
            // Any unrelated key or extra modifier cancels the pending G action.
            if type == .keyDown || (type == .flagsChanged &&
                (hasOtherModifiers || modifierFlagsRawValue & ActivationShortcutMatcher.leftCommandDeviceFlag != 0)) {
                pendingActivation = false
            }
            return false

        case .recoveryFailed:
            // Recovery faults must leave the user's entire keyboard usable,
            // including Space and shortcuts. Retry recovery through the menu;
            // Agent-generated input remains paused until recovery succeeds.
            return !EventOriginClassifier.isPhysical(sourcePID: sourcePID)

        case .guarding:
            guard EventOriginClassifier.isPhysical(sourcePID: sourcePID) else {
                return false
            }

            if type == .keyDown, keyCode == Self.spaceKeyCode, !isRepeat {
                Task { @MainActor [weak self] in
                    self?.spaceHandler?()
                }
            }
            return true

        case .authenticating:
            // Pause Agent-generated GUI input. Physical input is delivered to
            // the frontmost system authentication panel for password fallback.
            return !EventOriginClassifier.isPhysical(sourcePID: sourcePID)
        }
    }

    private func queueShortcut(activate: Bool) {
        let expectedGeneration = shortcutGeneration
        Task { @MainActor [weak self] in
            guard let self, self.state == .inactive,
                  self.shortcutGeneration == expectedGeneration else { return }
            if activate {
                self.activationShortcutHandler?()
            } else {
                self.displayShortcutHandler?()
            }
        }
    }

    private static let sKeyCode: Int64 = 1
    private static let spaceKeyCode: Int64 = 49
    private static let rightCommandKeyCode: Int64 = 54

    private static let eventMask: CGEventMask = {
        let types: [CGEventType] = [
            .keyDown,
            .keyUp,
            .flagsChanged,
            .mouseMoved,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .scrollWheel,
            .tabletPointer,
            .tabletProximity
        ]

        return types.reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << CGEventMask(type.rawValue))
        }
    }()
}
