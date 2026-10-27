import AppKit
import AgentGuardCore
@preconcurrency import ApplicationServices
import Foundation
import OSLog

@MainActor
final class GuardController {
    var onStateChange: ((GuardState, String?) -> Void)?
    var activationAllowed: () -> Bool = { true }
    private(set) var activationInProgress = false
    private var lastPublishedMessage: String?

    private let inputBlocker = InputBlocker()
    private let authenticator = AuthenticationController()
    private let keyboardBacklight = KeyboardBacklightController()
    private let powerController = PowerAssertionController()
    private let blackoutController = DisplayBlackoutController()
    private let secureInputStatus: () -> SecureInputStatus
    private let permissionCheck: ((Bool) -> Bool)?
    private let monitorHealth: Bool
    private var healthTimer: Timer?
    private var pendingResumeMessage: String?
    private var resumptionStartedAt: TimeInterval?
    private let monotonicNow: () -> TimeInterval
    private var displayRecoveryError: String?
    private let defaults: UserDefaults
    private(set) var state: GuardState = .inactive
    private(set) var displayMode: DisplayMode
    private let logger = Logger(subsystem: "com.local.agentguard", category: "GuardState")

    init(
        defaults: UserDefaults = .standard,
        secureInputStatus: @escaping () -> SecureInputStatus = { SecureInputStatus.current() },
        monitorHealth: Bool = true,
        permissionCheck: ((Bool) -> Bool)? = nil,
        monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.monotonicNow = monotonicNow
        self.secureInputStatus = secureInputStatus
        self.monitorHealth = monitorHealth
        self.permissionCheck = permissionCheck
        self.defaults = defaults
        let storedMode = defaults.string(forKey: DefaultsKey.displayMode)
        displayMode = DisplayMode(rawValue: storedMode ?? "") ?? .visible
    }

    var installationSafety: UpdateInstallGate.Safety {
        UpdateInstallGate.Safety(state: state,
            displayJournalActive: Self.recoveryJournalActive(at: DisplayRecoveryJournal.defaultURL),
            keyboardJournalActive: Self.recoveryJournalActive(at: KeyboardBacklightController.journalURL),
            activationInProgress: activationInProgress)
    }

    private static func recoveryJournalActive(at url: URL) -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return true
        } catch let error as NSError {
            // Permission/IO failures are unknown, never evidence of no recovery.
            return error.domain != NSCocoaErrorDomain
                || (error.code != NSFileNoSuchFileError && error.code != NSFileReadNoSuchFileError)
        }
    }

    var powerStatusText: String {
        switch displayMode {
        case .visible:
            return "防止电脑休眠，显示器保持常亮，关闭键盘背光"
        case .managedBlackout:
            return "防止电脑休眠，关闭键盘和内屏背光并软断开受管外屏"
        }
    }

    func requestPermissions(showPrompt: Bool) -> Bool {
        if let permissionCheck { return permissionCheck(showPrompt) }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: showPrompt] as CFDictionary
        let accessibilityGranted = AXIsProcessTrustedWithOptions(options)

        if showPrompt {
            _ = CGRequestListenEventAccess()
        }

        return accessibilityGranted
            && CGPreflightListenEventAccess()
    }

    private func restoreDisplays() -> String? {
        let error = blackoutController.restoreDisplays()
        displayRecoveryError = error
        return error
    }

    func recoverDisplaysOnLaunch() -> String? {
        let displayError = restoreDisplays()
        let keyboardError = keyboardBacklight.restore()
        let errors = [displayError, keyboardError].compactMap { $0 }
        let error = errors.isEmpty ? nil : errors.joined(separator: " ")
        if let error {
            transition(to: .recoveryFailed, message: error)
        }
        return error
    }

    func retryDisplayRecovery() {
        guard state != .guarding && state != .authenticating else { return }
        let displayError = restoreDisplays()
        let keyboardError = keyboardBacklight.restore()
        let errors = [displayError, keyboardError].compactMap { $0 }
        let error = errors.isEmpty ? nil : errors.joined(separator: " ")
        publishStateChange(state, error.map { "显示恢复待完成：" + $0 } ?? "显示恢复已完成。")
    }

    func setRecoveryMenuRegion(_ rect: CGRect?) {
        inputBlocker.recoveryMenuRegion = rect
    }

    func prepareActivationShortcut() {
        guard requestPermissions(showPrompt: false) else { return }
        if !installInputBlocker() {
            publishStateChange(state, "输入监听未就绪，快捷键不可用。请重新打开应用。")
        }
    }

    func activate() {
        guard state == .inactive, !activationInProgress else { return }
        activationInProgress = true
        defer {
            activationInProgress = false
            // A failed/aborted activation may never transition state. Let the
            // updater retry its deferred handler after the transaction ends.
            publishStateChange(state, lastPublishedMessage)
        }
        guard activationAllowed() else {
            publishStateChange(state, "正在安装更新，暂时不能开启托管。")
            return
        }
        let secure = secureInputStatus()
        guard !secure.enabled else {
            logger.error("Guard activation refused: Secure Input enabled")
            publishStateChange(state, secure.blockingMessage + " 未进入托管。")
            return
        }
        guard requestPermissions(showPrompt: true) else {
            publishStateChange(
                state,
                "需要在“系统设置 → 隐私与安全性”中允许辅助功能和输入监控，然后重新打开应用。"
            )
            return
        }

        let installed = installInputBlocker()
        guard installed else {
            publishStateChange(
                state,
                "输入监听未通过有效性检查，未进入托管。请检查辅助功能和输入监控权限，或重新打开应用。"
            )
            return
        }

        // Permissions/recovery may run UI callbacks; recheck before power/display side effects.
        let ready = secureInputStatus()
        guard !ready.enabled else {
            publishStateChange(state, ready.blockingMessage + " 未进入托管。")
            return
        }

        guard activationAllowed() else {
            publishStateChange(state, "正在安装更新，暂时不能开启托管。")
            return
        }
        if let error = restoreDisplays() {
            publishStateChange(state, error)
            return
        }
        let powerPolicy = PowerPolicy(
            preventSystemSleep: true,
            keepDisplayAwake: true
        )
        if let error = powerController.apply(powerPolicy) {
            publishStateChange(state, error)
            return
        }
        if let error = applyConfiguredDisplayMode() {
            powerController.release()
            publishStateChange(state, error)
            return
        }

        guard activationAllowed() else {
            deactivate() // undo display, keyboard and power effects before yielding
            let recoveryWarning = lastPublishedMessage
            publishStateChange(state, ["正在安装更新，未进入托管。", recoveryWarning].compactMap { $0 }.joined(separator: " "))
            return
        }
        transition(to: .guarding)
    }

    private func installInputBlocker() -> Bool {
        inputBlocker.installIfNeeded(
            spaceHandler: { [weak self] in
                self?.beginAuthentication()
            },
            activationShortcutHandler: { [weak self] in
                self?.activate()
            },
            displayShortcutHandler: { [weak self] in
                self?.toggleDisplayPreferenceFromShortcut()
            },
            failureHandler: { [weak self] in
                self?.handleInputFailure()
            }
        )
    }

    // Authentication teardown may leave Secure Input active briefly. Keep physical
    // actions blocked until BOTH Secure Input and the event tap are ready.
    func checkInputHealth() {
        if state == .restoringInput || (state == .recoveryFailed && pendingResumeMessage != nil) {
            completeInputResumptionIfReady()
            return
        }
        if state == .recoveryFailed {
            _ = installInputBlocker()
            return
        }
        guard state == .guarding else { return }
        if let error = keyboardBacklight.keepOff() {
            enterRecoveryFailure(error)
            return
        }
        let secure = secureInputStatus()
        if secure.enabled {
            enterRecoveryFailure(secure.blockingMessage)
        } else if !installInputBlocker() {
            handleInputFailure()
        } else if let error = blackoutController.healthError() {
            enterRecoveryFailure(error)
        }
    }

    private func updateHealthMonitoring() {
        healthTimer?.invalidate()
        healthTimer = nil
        guard (state == .guarding || state == .restoringInput || state == .recoveryFailed), monitorHealth else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkInputHealth() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    private func handleInputFailure() {
        enterRecoveryFailure("输入监听恢复失败，无法保证输入拦截。")
    }

    private func enterRecoveryFailure(_ reason: String) {
        pendingResumeMessage = nil
        resumptionStartedAt = nil
        inputBlocker.setState(.recoveryFailed)
        logger.fault("Guard recovery failed: \(reason, privacy: .public)")
        authenticator.cancel()
        let restoreError = restoreDisplays()
        let message = reason + " 请通过菜单重试验证解除或重新打开应用。"
            + (restoreError.map { " \($0)" } ?? "")
        // Losing input protection is not successful authentication. Preserve an
        // explicit fault state rather than silently reporting normal guarding.
        transition(to: state == .inactive ? .inactive : .recoveryFailed, message: message)
    }

    func deactivate() {
        pendingResumeMessage = nil
        resumptionStartedAt = nil
        authenticator.cancel()
        transition(to: .inactive)
    }

    func beginAuthentication() {
        guard state == .guarding || state == .recoveryFailed || state == .restoringInput else { return }
        // A broken listener must never gate the mouse/menu authentication escape path.
        // If healthy, retain it to suppress Agent-generated input during authentication.
        pendingResumeMessage = nil
        resumptionStartedAt = nil
        _ = installInputBlocker()
        transition(to: .authenticating)
        // Display availability must not gate identity verification. A powered-off
        // TV may reject reconnection while the built-in authentication screen works.
        let displayError = restoreDisplays()
        if let displayError {
            logger.error("Authentication continuing with pending display recovery: \(displayError, privacy: .public)")
            publishStateChange(.authenticating, "显示恢复待完成，仍可验证解除：" + displayError)
        }
        NSApp.activate(ignoringOtherApps: true)

        authenticator.authenticate(timeout: 10, willFinish: { [weak self] in
            // Revoke every authentication allowance before LAContext invalidation.
            self?.inputBlocker.setState(.restoringInput)
        }) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success:
                self.transition(to: .inactive)
            case .timedOut:
                self.resumeGuardingAfterAuthentication(
                    message: "验证已超时，托管模式继续。"
                )
            case .failed(let reason):
                self.resumeGuardingAfterAuthentication(
                    message: "未解除托管：\(reason)"
                )
            }
        }
    }

    func toggleDisplayPreferenceFromShortcut() {
        guard state == .inactive else { return }
        setDisplayMode(displayMode == .visible ? .managedBlackout : .visible)
    }

    @discardableResult
    func setDisplayMode(_ newMode: DisplayMode) -> String? {
        guard state != .authenticating && state != .restoringInput else {
            return "身份验证期间不能切换显示状态。"
        }
        if state == .recoveryFailed && newMode == .managedBlackout {
            return "托管恢复异常时不能进入黑屏。请先重试验证解除。"
        }
        if state == .guarding && newMode == .managedBlackout {
            let secure = secureInputStatus()
            if secure.enabled {
                enterRecoveryFailure(secure.blockingMessage)
                return secure.blockingMessage + " 未进入黑屏。"
            }
        }
        if state == .guarding && newMode == .managedBlackout && !installInputBlocker() {
            handleInputFailure()
            return "输入监听恢复失败，未进入黑屏。"
        }
        if state == .recoveryFailed && newMode == .visible,
           let error = restoreDisplays() {
            return error
        }
        let previousMode = displayMode
        displayMode = newMode

        if state == .guarding, let error = applyConfiguredDisplayMode() {
            displayMode = previousMode
            enterRecoveryFailure(error)
            return error
        }

        defaults.set(newMode.rawValue, forKey: DefaultsKey.displayMode)
        publishStateChange(state, displayRecoveryError.map { "显示恢复待完成：" + $0 })
        return nil
    }

    private func applyConfiguredDisplayMode() -> String? {
        switch displayMode {
        case .visible:
            return restoreDisplays()
        case .managedBlackout:
            let secure = secureInputStatus()
            guard !secure.enabled else { return secure.blockingMessage }
            return blackoutController.blackOutDisplays()
        }
    }

    private func resumeGuardingAfterAuthentication(message: String) {
        pendingResumeMessage = message
        resumptionStartedAt = monotonicNow()
        transition(to: .restoringInput, message: "认证已结束，正在恢复输入拦截；鼠标操作仍受限制。")
        completeInputResumptionIfReady()
    }

    private func completeInputResumptionIfReady() {
        guard let message = pendingResumeMessage else { return }
        let secure = secureInputStatus()
        let tapReady = installInputBlocker()
        guard !secure.enabled && tapReady else {
            if state == .restoringInput, monotonicNow() - (resumptionStartedAt ?? monotonicNow()) >= 3 {
                transition(to: .recoveryFailed,
                    message: "认证已结束，但输入保护尚未恢复；继续限制鼠标操作并自动重试。可按实体空格或从状态栏重试验证。")
            }
            return
        }
        // Installation can run callbacks: never black out before the final check.
        guard !secureInputStatus().enabled else { return }
        if let error = restoreDisplays() ?? applyConfiguredDisplayMode() {
            pendingResumeMessage = nil
            resumptionStartedAt = nil
            enterRecoveryFailure(error)
            return
        }
        pendingResumeMessage = nil
        resumptionStartedAt = nil
        transition(to: .guarding, message: message)
    }

    private func transition(to newState: GuardState, message: String? = nil) {
        if newState == .guarding {
            let secure = secureInputStatus()
            guard !secure.enabled else {
                enterRecoveryFailure(secure.blockingMessage)
                return
            }
        }
        logger.notice("Guard transition: \(String(describing: self.state), privacy: .public) -> \(String(describing: newState), privacy: .public)")
        inputBlocker.setState(newState)
        var finalMessage = message
        let keyboardError = newState == .guarding ? keyboardBacklight.turnOff() : keyboardBacklight.restore()
        if newState == .guarding, let keyboardError {
            enterRecoveryFailure(keyboardError)
            return
        }
        if let keyboardError {
            finalMessage = [finalMessage, keyboardError].compactMap { $0 }.joined(separator: " ")
        }
        if newState == .inactive {
            // Input authentication and display recovery are independent. Keep the
            // durable journal/watchdog on failure, but never re-lock authenticated input.
            if let error = restoreDisplays() {
                finalMessage = [finalMessage, "输入托管已解除；显示恢复待完成（未恢复的受管外屏可接回后重试）：" + error].compactMap { $0 }.joined(separator: " ")
            }
            powerController.release()
        }
        state = newState
        inputBlocker.setState(newState)
        updateHealthMonitoring()
        publishStateChange(newState, finalMessage)
    }

    private func publishStateChange(_ state: GuardState, _ message: String?) {
        lastPublishedMessage = message
        onStateChange?(state, message)
    }

    private enum DefaultsKey {
        static let displayMode = "com.local.agentguard.display-mode"
    }
}
