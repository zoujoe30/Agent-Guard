import Foundation

public enum ActivationShortcutMatcher {
    public static let gKeyCode: Int64 = 5
    // Device-dependent command-key bits from IOKit event flags. Quartz keeps
    // these bits on the G key event, allowing left and right Command to be
    // distinguished even though both share maskCommand.
    public static let leftCommandDeviceFlag: UInt64 = 0x08
    public static let rightCommandDeviceFlag: UInt64 = 0x10

    public static func isRightCommandPressed(modifierFlagsRawValue: UInt64) -> Bool {
        modifierFlagsRawValue & rightCommandDeviceFlag != 0
    }

    public static func matches(
        sourcePID: Int64,
        keyCode: Int64,
        isRepeat: Bool,
        modifierFlagsRawValue: UInt64,
        hasOtherModifiers: Bool
    ) -> Bool {
        EventOriginClassifier.isPhysical(sourcePID: sourcePID)
            && keyCode == gKeyCode
            && !isRepeat
            && isRightCommandPressed(modifierFlagsRawValue: modifierFlagsRawValue)
            && modifierFlagsRawValue & leftCommandDeviceFlag == 0
            && !hasOtherModifiers
    }
}
