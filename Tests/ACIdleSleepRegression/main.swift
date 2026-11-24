import Foundation
import IOKit.pwr_mgt

@MainActor
private final class Fixture {
    static let managedSystemID: IOPMAssertionID = 900
    static let managedDisplayID: IOPMAssertionID = 901
    var isOnAC: Bool? = false
    var canObserve = true
    var canAcquire = true
    var onObserve: (() -> Void)?
    var callbacks: [@MainActor () -> Void] = []
    var live: Set<IOPMAssertionID> = []
    var acquisitionAttempts = 0
    var cancellations = 0
    var released: [IOPMAssertionID] = []
    var nextID: IOPMAssertionID = 1

    var dependencies: ACIdleSleepController.Dependencies {
        .init(
            isOnAC: { self.isOnAC },
            observePower: { change in
                guard self.canObserve else { return nil }
                self.callbacks.append(change)
                self.onObserve?()
                return { self.cancellations += 1 }
            },
            acquire: {
                self.acquisitionAttempts += 1
                guard self.canAcquire else { return nil }
                let id = self.nextID
                self.nextID += 1
                self.live.insert(id)
                return id
            },
            release: {
                self.released.append($0)
                self.live.remove($0)
            }
        )
    }

    func changePower(_ onAC: Bool?) {
        isOnAC = onAC
        callbacks.last?()
    }

    func setManaged(_ managed: Bool) {
        // Simulate pre-existing independent system and display assertions.
        let ids = [Self.managedSystemID, Self.managedDisplayID]
        if managed { live.formUnion(ids) } else { live.subtract(ids) }
    }

    var optionalCount: Int {
        live.subtracting([Self.managedSystemID, Self.managedDisplayID]).count
    }

    var managedIsUntouched: Bool {
        !released.contains(Self.managedSystemID) && !released.contains(Self.managedDisplayID)
    }
}

@MainActor
private func run() {
    let suite = "AgentGuard.ACIdleSleepRegression.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let key = ACIdleSleepController.preferenceKey
    defer { defaults.removePersistentDomain(forName: suite) }
    var checks = 0
    func expect(_ value: @autoclosure () -> Bool, _ detail: String) {
        guard value() else { fatalError("FAILED: \(detail)") }
        checks += 1
    }

    for enabled in [false, true] {
        for ac in [false, true] {
            for managed in [false, true] {
                let fixture = Fixture()
                fixture.isOnAC = ac
                fixture.setManaged(managed)
                defaults.removeObject(forKey: key)
                if enabled { defaults.set(true, forKey: key) }
                let controller = ACIdleSleepController(defaults: defaults, dependencies: fixture.dependencies)
                controller.start()
                let label = "toggle=\(enabled), AC=\(ac), managed=\(managed)"
                expect(controller.isEnabled == enabled, "loaded preference: \(label)")
                expect(fixture.optionalCount == (enabled && ac ? 1 : 0), "optional assertion: \(label)")
                expect(fixture.callbacks.count == (enabled ? 1 : 0), "avoids monitoring when off: \(label)")
                expect(controller.status == (!enabled ? .disabled : ac ? .active : .waitingForAC), "optional status: \(label)")
                controller.stop()
                expect(fixture.optionalCount == 0, "quit releases optional assertion: \(label)")
                expect(fixture.live.contains(Fixture.managedSystemID) == managed &&
                       fixture.live.contains(Fixture.managedDisplayID) == managed &&
                       fixture.managedIsUntouched, "quit does not release managed assertions: \(label)")
            }
        }
    }

    defaults.removeObject(forKey: key)
    let fixture = Fixture()
    fixture.setManaged(true)
    let controller = ACIdleSleepController(defaults: defaults, dependencies: fixture.dependencies)
    var notifications = 0
    controller.onChange = { notifications += 1 }
    controller.start()
    expect(controller.status == .disabled && defaults.object(forKey: key) == nil, "upgrade defaults Off without writing it")
    controller.setEnabled(true)
    expect(defaults.bool(forKey: key) && controller.status == .waitingForAC && fixture.optionalCount == 0, "enable on battery persists but does not acquire")
    fixture.changePower(true)
    expect(controller.status == .active && fixture.live.contains(1), "plug while managed acquires a feature-specific assertion")
    fixture.setManaged(false)
    expect(fixture.live == [1], "ending managed mode leaves feature assertion active")
    fixture.changePower(true)
    expect(fixture.acquisitionAttempts == 1 && fixture.live == [1], "repeated AC event does not replace or duplicate")
    fixture.setManaged(true)
    fixture.changePower(false)
    expect(controller.status == .waitingForAC && fixture.optionalCount == 0 && fixture.released == [1] && fixture.managedIsUntouched,
           "unplug immediately releases only the feature assertion while managed")
    fixture.changePower(true)
    expect(fixture.live.contains(2), "replug reacquires a fresh assertion")
    fixture.changePower(nil)
    expect(controller.status == .powerUnavailable && fixture.released == [1, 2], "indeterminate power releases instead of assuming AC")
    fixture.changePower(true)
    let staleCallback = fixture.callbacks[0]
    controller.setEnabled(false)
    expect(!defaults.bool(forKey: key) && fixture.released == [1, 2, 3] && fixture.cancellations == 1, "disabling on AC persists and releases immediately")
    let afterDisable = notifications
    staleCallback()
    expect(notifications == afterDisable && fixture.optionalCount == 0, "queued callback after disable cannot re-enable")
    controller.setEnabled(true)
    expect(fixture.callbacks.count == 2 && fixture.live.contains(4), "enable on AC samples immediately and starts a new observer")
    staleCallback()
    expect(fixture.live.contains(4) && notifications == afterDisable + 1, "callback from earlier observer cannot affect its replacement")
    controller.stop()
    controller.stop()
    let afterQuit = notifications
    fixture.changePower(true)
    expect(defaults.bool(forKey: key) && fixture.released == [1, 2, 3, 4] && fixture.cancellations == 2 &&
           notifications == afterQuit && fixture.managedIsUntouched, "quit is idempotent, drops queued callback, preserves preference and managed IDs")
    let relaunched = ACIdleSleepController(defaults: defaults, dependencies: fixture.dependencies)
    relaunched.start()
    expect(relaunched.isEnabled && relaunched.status == .active && fixture.live.contains(5), "relaunch reads persisted toggle and current AC")
    relaunched.stop()

    let failure = Fixture()
    failure.isOnAC = true
    failure.canObserve = false
    let noObserver = ACIdleSleepController(defaults: defaults, dependencies: failure.dependencies)
    noObserver.start()
    expect(noObserver.status == .powerUnavailable && failure.acquisitionAttempts == 0, "cannot acquire if change monitoring is unavailable")
    failure.canObserve = true
    failure.canAcquire = false
    noObserver.setEnabled(true)
    expect(noObserver.status == .assertionUnavailable && failure.optionalCount == 0, "OS assertion denial is visible and holds no assertion")
    failure.canAcquire = true
    failure.changePower(true)
    expect(noObserver.status == .active && failure.optionalCount == 1, "next live event can recover a failed acquisition")
    noObserver.stop()
    expect(failure.optionalCount == 0, "failure recovery also releases on quit")

    let startup = Fixture()
    startup.isOnAC = false
    startup.onObserve = { startup.isOnAC = true }
    let duringRegistration = ACIdleSleepController(defaults: defaults, dependencies: startup.dependencies)
    duringRegistration.start()
    expect(duringRegistration.status == .active, "prevents missing power transition during listener registration")
    duringRegistration.start()
    expect(startup.callbacks.count == 1 && startup.acquisitionAttempts == 1, "redundant start does not add listener or assertion")
    duringRegistration.stop()
    print("PASS: \(checks) AC-only idle-sleep checks")
}

run()
