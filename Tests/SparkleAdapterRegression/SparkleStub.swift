import AppKit
import Foundation

@MainActor public protocol SPUUpdaterDelegate: AnyObject {}
@MainActor public protocol SPUUserDriver: AnyObject {}
public protocol SPUStandardUserDriverDelegate: AnyObject {
    var supportsGentleScheduledUpdateReminders: Bool { get }
    func standardUserDriverWillHandleShowingUpdate(_ handle: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState)
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem)
    func standardUserDriverWillFinishUpdateSession()
}
public enum SPUUpdateCheck { case updates, background }
public enum SPUUserUpdateChoice { case install, dismiss, skip }
public enum SPUUserUpdateStage { case notDownloaded, downloaded, installing }
@MainActor public final class SUAppcastItem: NSObject {
    public var displayVersionString = "9.9"
}
@MainActor public final class SPUUserUpdateState: NSObject {
    public let stage: SPUUserUpdateStage
    public init(stage: SPUUserUpdateStage) { self.stage = stage }
}
@MainActor public final class SPUUpdatePermissionRequest: NSObject {}
@MainActor public final class SUUpdatePermissionResponse: NSObject {}
@MainActor public final class SPUDownloadData: NSObject {}
@MainActor public final class SPUUpdater: NSObject {
    public static var latest: SPUUpdater?
    @objc public dynamic var canCheckForUpdates = true
    public var automaticallyChecksForUpdates = true
    public var automaticallyDownloadsUpdates = false
    public var checkInvocations = 0
    public init(hostBundle: Bundle, applicationBundle: Bundle, userDriver: any SPUUserDriver, delegate: any SPUUpdaterDelegate) {
        super.init()
        Self.latest = self
    }
    public func start() throws {}
    public func checkForUpdates() { checkInvocations += 1 }
}
@MainActor public final class SPUStandardUserDriver: NSObject {
    public static weak var standardDelegate: (any SPUStandardUserDriverDelegate)?
    public static var foundReply: ((SPUUserUpdateChoice) -> Void)?
    public static var readyReply: ((SPUUserUpdateChoice) -> Void)?
    public static var retryTermination: (() -> Void)?
    public init(hostBundle: Bundle, delegate: (any SPUStandardUserDriverDelegate)?) { Self.standardDelegate = delegate }
    public func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {}
    public func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    public func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        Self.foundReply = reply
        Self.standardDelegate?.standardUserDriverWillHandleShowingUpdate(true, forUpdate: item, state: state)
    }
    public func showUpdateReleaseNotes(with data: SPUDownloadData) {}
    public func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    public func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {}
    public func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {}
    public func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    public func showDownloadDidReceiveExpectedContentLength(_ length: UInt64) {}
    public func showDownloadDidReceiveData(ofLength length: UInt64) {}
    public func showDownloadDidStartExtractingUpdate() {}
    public func showExtractionReceivedProgress(_ progress: Double) {}
    public func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { Self.readyReply = reply }
    public func showInstallingUpdate(withApplicationTerminated terminated: Bool, retryTerminatingApplication: @escaping () -> Void) { Self.retryTermination = retryTerminatingApplication }
    public func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {}
    public func dismissUpdateInstallation() {}
    public func showUpdateInFocus() {}
}
