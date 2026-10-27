import AgentGuardCore
import Darwin

let checks: [(String, Bool)] = [
    ("PID 0 is physical", EventOriginClassifier.isPhysical(sourcePID: 0)),
    ("PID -1 is physical", EventOriginClassifier.isPhysical(sourcePID: -1)),
    ("userspace PID is synthetic", !EventOriginClassifier.isPhysical(sourcePID: 1234)),
    (
        "system sleep prevention can allow display sleep",
        PowerPolicy(
            preventSystemSleep: true,
            keepDisplayAwake: false
        ) == PowerPolicy(
            preventSystemSleep: true,
            keepDisplayAwake: false
        )
    ),
    (
        "display can stay awake while system sleep is prevented",
        PowerPolicy(
            preventSystemSleep: true,
            keepDisplayAwake: true
        ).keepDisplayAwake
    ),
    (
        "display assertion is disabled with system sleep prevention",
        !PowerPolicy(
            preventSystemSleep: false,
            keepDisplayAwake: true
        ).keepDisplayAwake
    ),
    ("visible display mode persists", DisplayMode(rawValue: "visible") == .visible),
    (
        "managed blackout display mode persists",
        DisplayMode(rawValue: "managedBlackout") == .managedBlackout
    ),
    (
        "status command parses",
        AgentGuardControlCommand(arguments: ["status"]) == .status
    ),
    (
        "visible command round trips",
        AgentGuardControlCommand(wireValue: "display visible")
            == .display(.visible)
    ),
    (
        "blackout command round trips",
        AgentGuardControlCommand(arguments: ["display", "blackout"])?
            .wireValue == "display blackout"
    ),
    (
        "physical right Command-G activates",
        ActivationShortcutMatcher.matches(
            sourcePID: 0,
            keyCode: ActivationShortcutMatcher.gKeyCode,
            isRepeat: false,
            modifierFlagsRawValue: ActivationShortcutMatcher.rightCommandDeviceFlag,
            hasOtherModifiers: false
        )
    ),
    (
        "synthetic right Command-G does not activate",
        !ActivationShortcutMatcher.matches(
            sourcePID: 1234,
            keyCode: ActivationShortcutMatcher.gKeyCode,
            isRepeat: false,
            modifierFlagsRawValue: ActivationShortcutMatcher.rightCommandDeviceFlag,
            hasOtherModifiers: false
        )
    ),
    (
        "left Command-G does not activate",
        !ActivationShortcutMatcher.matches(
            sourcePID: 0,
            keyCode: ActivationShortcutMatcher.gKeyCode,
            isRepeat: false,
            modifierFlagsRawValue: ActivationShortcutMatcher.leftCommandDeviceFlag,
            hasOtherModifiers: false
        )
    ),
    (
        "both Command keys with G do not activate",
        !ActivationShortcutMatcher.matches(
            sourcePID: 0,
            keyCode: ActivationShortcutMatcher.gKeyCode,
            isRepeat: false,
            modifierFlagsRawValue: ActivationShortcutMatcher.leftCommandDeviceFlag
                | ActivationShortcutMatcher.rightCommandDeviceFlag,
            hasOtherModifiers: false
        )
    ),
    (
        "G without Command does not activate",
        !ActivationShortcutMatcher.matches(
            sourcePID: 0,
            keyCode: ActivationShortcutMatcher.gKeyCode,
            isRepeat: false,
            modifierFlagsRawValue: 0,
            hasOtherModifiers: false
        )
    ),
    (
        "right Command-G with another modifier does not activate",
        !ActivationShortcutMatcher.matches(
            sourcePID: 0,
            keyCode: ActivationShortcutMatcher.gKeyCode,
            isRepeat: false,
            modifierFlagsRawValue: ActivationShortcutMatcher.rightCommandDeviceFlag,
            hasOtherModifiers: true
        )
    ),
    (
        "repeated right Command-G does not activate",
        !ActivationShortcutMatcher.matches(
            sourcePID: 0,
            keyCode: ActivationShortcutMatcher.gKeyCode,
            isRepeat: true,
            modifierFlagsRawValue: ActivationShortcutMatcher.rightCommandDeviceFlag,
            hasOtherModifiers: false
        )
    )
]

let allChecks = checks + eventTapRecoveryChecks()
let failures = allChecks.filter { !$0.1 }
if failures.isEmpty {
    print("AgentGuardSelfTest: \(allChecks.count)/\(allChecks.count) checks passed")
    exit(EXIT_SUCCESS)
}

for failure in failures {
    fputs("FAIL: \(failure.0)\n", stderr)
}
exit(EXIT_FAILURE)
