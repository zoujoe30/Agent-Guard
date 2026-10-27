import AppKit
import Sparkle

/// All install replies pass through the same main-actor lease as guard activation.
/// Keep Sparkle's standard UI, signature verification, download and installer.
@MainActor
final class SparkleUpdateController: NSObject, SPUUpdaterDelegate, SPUUserDriver {
    private let gate: UpdateInstallGate
    private let safety: () -> UpdateInstallGate.Safety
    private let standard = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
    private var updater: SPUUpdater!
    private var session: UUID?
    private var cancellationRequested = false
    private var answeredRequests: Set<UUID> = []
    private var checkObservation: NSKeyValueObservation?
    var onChange: (() -> Void)?
    private(set) var startupError: String?
    var blocksActivation: Bool { gate.blocksActivation }
    var hasDeferredInstall: Bool { gate.hasDeferredInstall }
    var canCheck: Bool { updater?.canCheckForUpdates == true && safety().permitsInstallation && !blocksActivation }
    var automaticallyChecks: Bool { updater?.automaticallyChecksForUpdates == true }
    var permitsTermination: Bool {
        if let session, blocksActivation { return gate.permitsTermination(session: session) }
        return safety().permitsInstallation
    }

    init(safety: @escaping () -> UpdateInstallGate.Safety) {
        self.safety = safety
        gate = UpdateInstallGate(safety: safety)
        super.init()
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        checkObservation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    func start() {
        do { try updater.start() } catch { startupError = error.localizedDescription }
        onChange?()
    }
    func checkForUpdates() { if canCheck { updater.checkForUpdates() } }
    func toggleAutomaticChecks() {
        updater.automaticallyChecksForUpdates.toggle()
        onChange?()
    }
    func guardStateDidChange() { gate.resumeIfSafe(); onChange?() }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard safety().permitsInstallation, !blocksActivation,
              let next = gate.beginSession() else {
            throw NSError(domain: "AgentGuard.Update", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "托管、认证或恢复期间暂停检查更新，请解除托管后重试。"])
        }
        session = next
        cancellationRequested = false
        answeredRequests.removeAll()
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        submitInstall(installHandler, session: session, request: UUID())
        return true
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { finishSession() }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        // A successful cycle may still have an installer queued for quit.
        if error != nil || cancellationRequested || !blocksActivation && !hasDeferredInstall { finishSession() }
        onChange?()
    }

    private func submitInstall(_ handler: @escaping () -> Void, session token: UUID?, request: UUID) {
        guard let token, session == token else { return } // fail closed for an unknown/expired cycle
        gate.submit(session: token, requestID: request, handler: handler)
        onChange?()
    }
    private func finishSession() {
        if let session { gate.finish(session: session) }
        session = nil
        cancellationRequested = false
        answeredRequests.removeAll()
        onChange?()
    }
    private func forwardChoice(_ choice: SPUUserUpdateChoice, reply: @escaping (SPUUserUpdateChoice) -> Void,
                               session token: UUID?, request: UUID) {
        guard let token, session == token, !answeredRequests.contains(request) else { return }
        answeredRequests.insert(request)
        if choice == .install {
            gate.submit(session: token, requestID: request) { reply(choice) }
        } else {
            // Sparkle dispatches reply handling asynchronously. Skip REQUESTS
            // cancellation; retain the lease until didAbort/didFinish confirms it.
            // Dismiss preserves a prepared install-on-quit and never releases it.
            if choice == .skip { cancellationRequested = true }
            reply(choice)
        }
        onChange?()
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        standard.show(request, reply: reply)
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        standard.showUserInitiatedUpdateCheck(cancellation: cancellation)
    }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let token = session, request = UUID()
        standard.showUpdateFound(with: appcastItem, state: state) { [weak self] choice in
            self?.forwardChoice(choice, reply: reply, session: token, request: request)
        }
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) { standard.showUpdateReleaseNotes(with: downloadData) }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { standard.showUpdateReleaseNotesFailedToDownloadWithError(error) }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        standard.showUpdaterError(error, acknowledgement: acknowledgement)
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { standard.showDownloadInitiated(cancellation: cancellation) }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength) }
    func showDownloadDidReceiveData(ofLength length: UInt64) { standard.showDownloadDidReceiveData(ofLength: length) }
    func showDownloadDidStartExtractingUpdate() { standard.showDownloadDidStartExtractingUpdate() }
    func showExtractionReceivedProgress(_ progress: Double) { standard.showExtractionReceivedProgress(progress) }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let token = session, request = UUID()
        standard.showReady(toInstallAndRelaunch: { [weak self] choice in
            self?.forwardChoice(choice, reply: reply, session: token, request: request)
        })
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        let token = session, request = UUID()
        standard.showInstallingUpdate(withApplicationTerminated: applicationTerminated) { [weak self] in
            guard !applicationTerminated else { return }
            self?.submitInstall(retryTerminatingApplication, session: token, request: request)
        }
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        finishSession()
        standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
    }
    func dismissUpdateInstallation() { standard.dismissUpdateInstallation() }
    func showUpdateInFocus() { standard.showUpdateInFocus() }
}
