import Foundation

/// Serializes installation with guarding on the main actor. The Sparkle adapter
/// must acquire this gate BEFORE forwarding ANY install reply, including a reply
/// that merely begins downloading. Keep the session locked until its terminal
/// cancel/failure/completion callback; dismissing an installation window is not
/// proof the installer has stopped or will not install on application exit.
@MainActor
final class UpdateInstallGate {
    struct Safety {
        let state: GuardState
        let displayJournalActive: Bool
        let keyboardJournalActive: Bool
        let activationInProgress: Bool

        init(state: GuardState, displayJournalActive: Bool, keyboardJournalActive: Bool,
             activationInProgress: Bool = false) {
            self.state = state
            self.displayJournalActive = displayJournalActive
            self.keyboardJournalActive = keyboardJournalActive
            self.activationInProgress = activationInProgress
        }
        var permitsInstallation: Bool {
            state == .inactive && !displayJournalActive && !keyboardJournalActive && !activationInProgress
        }
    }
    enum Decision: Equatable {
        case committed
        case deferred
        /// Old session, repeated request ID, or another request is already waiting.
        case ignored
    }
    private struct Pending {
        let session: UUID
        let request: UUID
        let handler: () -> Void
    }
    private let safety: () -> Safety
    private var sessionID: UUID?
    private var consumedRequests: Set<UUID> = []
    private var pending: Pending?
    private(set) var blocksActivation = false
    var hasDeferredInstall: Bool { pending != nil }

    init(safety: @escaping () -> Safety) { self.safety = safety }

    /// Begin one updater cycle. A newer pre-install cycle invalidates every old
    /// reply; a committed cycle can only be released by finish(session:).
    @discardableResult
    func beginSession() -> UUID? {
        guard !blocksActivation else { return nil }
        let session = UUID()
        sessionID = session
        pending = nil
        consumedRequests.removeAll()
        return session
    }

    /// Allocate requestID once per Sparkle reply/installHandler and capture it in
    /// the UI callback. Reusing that callback cannot forward installation twice.
    /// Subsequent stages in the SAME committed updater cycle use fresh requestIDs
    /// and retain the existing activation lock.
    @discardableResult
    func submit(session: UUID, requestID: UUID, handler: @escaping () -> Void) -> Decision {
        guard sessionID == session, !consumedRequests.contains(requestID), pending == nil else { return .ignored }
        consumedRequests.insert(requestID)
        pending = Pending(session: session, request: requestID, handler: handler)
        return resumeIfSafe()
    }

    /// Call after authentication/display/keyboard recovery changes. No detached
    /// task or delayed block bypasses the final safety snapshot at the commit.
    @discardableResult
    func resumeIfSafe() -> Decision {
        guard let candidate = pending, sessionID == candidate.session else { return .ignored }
        let ready = safety().permitsInstallation
        // The provider must be a synchronous snapshot, but reject a candidate
        // invalidated by reentrant lifecycle callbacks even if that changes.
        guard let current = pending, current.session == candidate.session,
              current.request == candidate.request, sessionID == candidate.session else { return .ignored }
        guard ready else { return .deferred }
        blocksActivation = true
        pending = nil // consume before invoking arbitrary/reentrant Sparkle code
        candidate.handler()
        return .committed
    }

    /// Use only for a CONFIRMED terminal update cancellation, failure or completion.
    /// An old callback cannot unlock a different update cycle. Do not call this
    /// for window dismissal or a successfully postponed/queued install-on-quit.
    @discardableResult
    func finish(session: UUID) -> Bool {
        guard sessionID == session else { return false }
        pending = nil
        consumedRequests.removeAll()
        sessionID = nil
        blocksActivation = false
        return true
    }

    /// Defense in depth immediately before allowing Sparkle-driven termination.
    /// This does not acquire a lock: all install entry points must submit first.
    func permitsTermination(session: UUID) -> Bool {
        guard sessionID == session, blocksActivation, pending == nil else { return false }
        let ready = safety().permitsInstallation
        return ready && sessionID == session && blocksActivation && pending == nil
    }
}
