/// Two stages form one input protection boundary. A partial pair is never healthy.
@MainActor
public final class EventTapPairDriver: EventTapDriver {
    private let first: any EventTapDriver
    private let second: any EventTapDriver

    public init(first: any EventTapDriver, second: any EventTapDriver) {
        self.first = first
        self.second = second
    }

    public var isValid: Bool { first.isValid && second.isValid }
    public var isEnabled: Bool { isValid && first.isEnabled && second.isEnabled }

    public func enable() {
        guard isValid else { return }
        first.enable()
        second.enable()
    }

    public func invalidate() {
        first.invalidate()
        second.invalidate()
    }

    public func create() -> Bool {
        invalidate()
        guard first.create(), second.create(), isValid else {
            invalidate()
            return false
        }
        return true
    }
}
