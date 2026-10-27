/// Operations needed to recover an event tap without treating a retained handle
/// as proof of a working listener. Implementations also validate the run-loop source.
@MainActor
public protocol EventTapDriver: AnyObject {
    var isValid: Bool { get }
    var isEnabled: Bool { get }
    func enable()
    func invalidate()
    func create() -> Bool
}

public enum EventTapRecovery {
    /// At most one rebuild. Success proves validity/enabled state, not keyboard
    /// reachability (for example, Secure Input can still suppress keyboard events).
    @MainActor
    public static func ensureHealthy(_ driver: any EventTapDriver) -> Bool {
        if driver.isValid {
            if !driver.isEnabled { driver.enable() }
            if driver.isValid && driver.isEnabled { return true }
        }

        driver.invalidate()
        guard driver.create() else {
            driver.invalidate()
            return false
        }
        driver.enable()
        guard driver.isValid && driver.isEnabled else {
            driver.invalidate()
            return false
        }
        return true
    }
}
