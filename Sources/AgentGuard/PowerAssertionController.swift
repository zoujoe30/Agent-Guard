import AgentGuardCore
import Foundation
import IOKit.pwr_mgt

@MainActor
final class PowerAssertionController {
    private var systemAssertionID: IOPMAssertionID?
    private var displayAssertionID: IOPMAssertionID?

    private(set) var activePolicy = PowerPolicy(
        preventSystemSleep: false,
        keepDisplayAwake: false
    )

    func apply(_ policy: PowerPolicy) -> String? {
        release()

        guard policy.preventSystemSleep else {
            return nil
        }

        var systemID: IOPMAssertionID = 0
        let systemResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Agent Guard 托管期间防止电脑休眠" as CFString,
            &systemID
        )
        guard systemResult == kIOReturnSuccess else {
            return "无法启用防休眠，系统错误码：\(systemResult)"
        }
        systemAssertionID = systemID

        if policy.keepDisplayAwake {
            var displayID: IOPMAssertionID = 0
            let displayResult = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Agent Guard 托管期间保持显示器常亮" as CFString,
                &displayID
            )
            guard displayResult == kIOReturnSuccess else {
                release()
                return "无法保持显示器常亮，系统错误码：\(displayResult)"
            }
            displayAssertionID = displayID
        }

        activePolicy = policy
        return nil
    }

    func release() {
        if let displayAssertionID {
            IOPMAssertionRelease(displayAssertionID)
            self.displayAssertionID = nil
        }
        if let systemAssertionID {
            IOPMAssertionRelease(systemAssertionID)
            self.systemAssertionID = nil
        }
        activePolicy = PowerPolicy(
            preventSystemSleep: false,
            keepDisplayAwake: false
        )
    }
}
