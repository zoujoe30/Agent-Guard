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
    // Fault injection against the pair driver used by the real InputBlocker.
    for side in 0...1 {
        let first = FakeTap(), second = FakeTap()
        let pair = EventTapPairDriver(first: first, second: second)
        let broken = side == 0 ? first : second
        broken.creationWorks = false
        checks.append(("pair creation failure side \(side) cleans both endpoints",
            !EventTapRecovery.ensureHealthy(pair) && !first.isValid && !second.isValid
            && !first.isEnabled && !second.isEnabled))
        broken.creationWorks = true
        checks.append(("pair failure side \(side) remains retryable", EventTapRecovery.ensureHealthy(pair)))
        first.calls = []; second.calls = []
        broken.isEnabled = false
        checks.append(("single disabled endpoint side \(side) marks pair unhealthy", !pair.isEnabled))
        checks.append(("single disabled endpoint side \(side) re-enables without replacement",
            EventTapRecovery.ensureHealthy(pair) && !first.calls.contains("create") && !second.calls.contains("create")))
        first.calls = []; second.calls = []
        broken.isValid = false
        checks.append(("single invalid endpoint side \(side) invalidates whole pair", !pair.isValid && !pair.isEnabled))
        checks.append(("single invalid endpoint side \(side) rebuilds whole pair",
            EventTapRecovery.ensureHealthy(pair) && first.calls.contains("create") && second.calls.contains("create")))
        broken.enableWorks = false
        broken.isEnabled = false
        checks.append(("single stuck endpoint side \(side) cannot degrade to one healthy tap",
            !EventTapRecovery.ensureHealthy(pair) && !first.isValid && !second.isValid))
    }
    let first = FakeTap(), second = FakeTap()
    let invalidPair = EventTapPairDriver(first: first, second: second)
    second.newSourceValid = false
    checks.append(("pair rejects reported creation success with invalid run-loop source",
        !EventTapRecovery.ensureHealthy(invalidPair) && !first.isValid && !second.isValid))
    return checks
}
