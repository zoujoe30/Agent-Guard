import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Owns only the optional AC idle-system-sleep assertion. Managed mode owns a
/// different assertion and lifecycle; display sleep and locking are not touched.
@MainActor
final class ACIdleSleepController {
    enum Status: Equatable {
        case disabled
        case waitingForAC
        case powerUnavailable
        case assertionUnavailable
        case active
    }

    struct Dependencies {
        let isOnAC: () -> Bool?
        let observePower: (@escaping @MainActor () -> Void) -> (() -> Void)?
        let acquire: () -> IOPMAssertionID?
        let release: (IOPMAssertionID) -> Void

        static var system: Self {
            Self(
                isOnAC: {
                    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
                          let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue()
                    else { return nil }
                    switch source as String {
                    case kIOPMACPowerKey: return true
                    case kIOPMBatteryPowerKey, kIOPMUPSPowerKey: return false
                    default: return nil
                    }
                },
                observePower: { change in
                    guard let observation = ACSystemPowerObservation(onChange: change) else {
                        return nil
                    }
                    return { observation.cancel() }
                },
                acquire: {
                    var id: IOPMAssertionID = 0
                    let result = IOPMAssertionCreateWithName(
                        kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                        "Agent Guard 插电时防止电脑空闲休眠" as CFString,
                        &id
                    )
                    return result == kIOReturnSuccess ? id : nil
                },
                release: { _ = IOPMAssertionRelease($0) }
            )
        }
    }

    static let preferenceKey = "com.local.agentguard.prevent-idle-system-sleep-on-ac"
    private let defaults: UserDefaults
    private let dependencies: Dependencies
    private var running = false
    private var observationGeneration: UInt64 = 0
    private var stopObserving: (() -> Void)?
    private var assertion: IOPMAssertionID?
    private(set) var isEnabled = false
    private(set) var status: Status = .disabled
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard, dependencies: Dependencies = .system) {
        self.defaults = defaults
        self.dependencies = dependencies
    }

    func start() {
        guard !running else { return }
        running = true
        // An absent preference is false, including upgrades from older builds.
        isEnabled = defaults.bool(forKey: Self.preferenceKey)
        updateMonitoring()
    }

    func setEnabled(_ enabled: Bool) {
        guard running else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.preferenceKey)
        updateMonitoring()
    }

    func stop() {
        guard running else { return }
        running = false
        cancelMonitoring()
        releaseAssertion()
        status = .disabled
    }

    private func updateMonitoring() {
        if isEnabled {
            if stopObserving == nil {
                observationGeneration &+= 1
                let generation = observationGeneration
                stopObserving = dependencies.observePower { [weak self] in
                    guard let self, self.observationGeneration == generation else { return }
                    self.refreshPower()
                }
            }
            // Subscribe before sampling so a transition during startup is not lost.
            refreshPower()
        } else {
            cancelMonitoring()
            releaseAssertion()
            status = .disabled
            onChange?()
        }
    }

    private func refreshPower() {
        guard running, isEnabled else { return }
        switch stopObserving == nil ? nil : dependencies.isOnAC() {
        case true?:
            if assertion == nil { assertion = dependencies.acquire() }
            status = assertion == nil ? .assertionUnavailable : .active
        case false?:
            releaseAssertion()
            status = .waitingForAC
        case nil:
            // Do not leave an assertion active without confirmed AC and a working observer.
            releaseAssertion()
            status = .powerUnavailable
        }
        onChange?()
    }

    private func cancelMonitoring() {
        observationGeneration &+= 1
        let cancel = stopObserving
        stopObserving = nil
        cancel?()
    }

    private func releaseAssertion() {
        guard let id = assertion else { return }
        assertion = nil
        dependencies.release(id)
    }
}

/// The notification source is scheduled only on the main run loop. Invalidating
/// it before releasing its context also covers deallocation without explicit stop.
private final class ACSystemPowerObservation {
    private let onChange: @MainActor () -> Void
    private var source: CFRunLoopSource?

    init?(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ rawContext in
            guard let rawContext else { return }
            let onChange = Unmanaged<ACSystemPowerObservation>.fromOpaque(rawContext).takeUnretainedValue().onChange
            MainActor.assumeIsolated { onChange() }
        }, context)?.takeRetainedValue() else { return nil }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func cancel() {
        if let source { CFRunLoopSourceInvalidate(source) }
        source = nil
    }

    deinit { cancel() }
}
