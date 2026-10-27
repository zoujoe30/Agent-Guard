import AgentGuardCore

@MainActor
private final class FakeTap: EventTapDriver {
    var isValid = false
    var isEnabled = false
    var enableWorks = true
    var creationWorks = true
    var newSourceValid = true
    var invalidateDuringEnable = false
    var calls: [String] = []

    func enable() {
        calls.append("enable")
        isEnabled = enableWorks
        if invalidateDuringEnable { isValid = false }
    }
    func invalidate() {
        calls.append("invalidate")
        isValid = false
        isEnabled = false
    }
    func create() -> Bool {
        calls.append("create")
        isValid = creationWorks && newSourceValid
        return creationWorks
    }
}

@MainActor
func eventTapRecoveryChecks() -> [(String, Bool)] {
    var checks: [(String, Bool)] = []

    let healthy = FakeTap()
    healthy.isValid = true
    healthy.isEnabled = true
    checks.append(("healthy tap is reused without interruption",
                   EventTapRecovery.ensureHealthy(healthy) && healthy.calls.isEmpty))

    let disabled = FakeTap()
    disabled.isValid = true
    checks.append(("disabled tap is enabled and read back without replacement",
                   EventTapRecovery.ensureHealthy(disabled) && disabled.calls == ["enable"]))

    let stale = FakeTap()
    stale.isEnabled = true
    checks.append(("invalid handle/source cannot pass on enabled flag alone",
                   EventTapRecovery.ensureHealthy(stale)
                   && stale.calls == ["invalidate", "create", "enable"]))

    let unavailable = FakeTap()
    unavailable.creationWorks = false
    checks.append(("creation failure denies activation and leaves no tap",
                   !EventTapRecovery.ensureHealthy(unavailable)
                   && !unavailable.isValid && !unavailable.isEnabled
                   && unavailable.calls == ["invalidate", "create", "invalidate"]))

    let stuckDisabled = FakeTap()
    stuckDisabled.isValid = true
    stuckDisabled.enableWorks = false
    checks.append(("unsuccessful enable gets one rebuild then fails closed",
                   !EventTapRecovery.ensureHealthy(stuckDisabled)
                   && stuckDisabled.calls == ["enable", "invalidate", "create", "enable", "invalidate"]
                   && !stuckDisabled.isValid && !stuckDisabled.isEnabled))

    let brokenSource = FakeTap()
    brokenSource.newSourceValid = false
    checks.append(("creation success with invalid source is rejected and cleaned",
                   !EventTapRecovery.ensureHealthy(brokenSource)
                   && !brokenSource.isValid && !brokenSource.isEnabled))

    let invalidated = FakeTap()
    invalidated.isValid = true
    invalidated.invalidateDuringEnable = true
    checks.append(("invalidation during enable cannot pass enabled read-back",
                   !EventTapRecovery.ensureHealthy(invalidated)
                   && !invalidated.isValid && !invalidated.isEnabled))

    unavailable.creationWorks = true
    unavailable.calls = []
    checks.append(("failed recovery remains retryable after environment recovers",
                   EventTapRecovery.ensureHealthy(unavailable)
                   && unavailable.calls == ["invalidate", "create", "enable"]))
    return checks
}
