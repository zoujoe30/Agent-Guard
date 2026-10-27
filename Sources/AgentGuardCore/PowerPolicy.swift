public struct PowerPolicy: Equatable, Sendable {
    public let preventSystemSleep: Bool
    public let keepDisplayAwake: Bool

    public init(preventSystemSleep: Bool, keepDisplayAwake: Bool) {
        self.preventSystemSleep = preventSystemSleep
        self.keepDisplayAwake = preventSystemSleep && keepDisplayAwake
    }
}
