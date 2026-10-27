import AgentGuardCore
import CoreFoundation
import Foundation

@MainActor
final class ControlServer {
    private let guardController: GuardController
    private var port: CFMessagePort?
    private var runLoopSource: CFRunLoopSource?

    init(guardController: GuardController) {
        self.guardController = guardController
    }

    func start() -> String? {
        guard port == nil else { return nil }

        var context = CFMessagePortContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        var shouldFreeInfo = DarwinBoolean(false)
        guard let port = CFMessagePortCreateLocal(
            kCFAllocatorDefault,
            AgentGuardControl.portName as CFString,
            Self.callback,
            &context,
            &shouldFreeInfo
        ) else {
            return "无法启动本地控制接口；可能已有另一个 Agent Guard 实例。"
        }

        let source = CFMessagePortCreateRunLoopSource(
            kCFAllocatorDefault,
            port,
            0
        )
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.port = port
        runLoopSource = source
        return nil
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                runLoopSource,
                .commonModes
            )
            self.runLoopSource = nil
        }
        if let port {
            CFMessagePortInvalidate(port)
            self.port = nil
        }
    }

    private func handle(_ data: Data) -> Data {
        guard
            let wireValue = String(data: data, encoding: .utf8),
            let command = AgentGuardControlCommand(wireValue: wireValue)
        else {
            return encodeResponse(
                ok: false,
                error: "不支持的命令。"
            )
        }

        switch command {
        case .status:
            return encodeResponse(ok: true)

        case .display(let mode):
            if let error = guardController.setDisplayMode(mode) {
                return encodeResponse(ok: false, error: error)
            }
            return encodeResponse(ok: true)
        }
    }

    private func encodeResponse(
        ok: Bool,
        error: String? = nil
    ) -> Data {
        let response = AgentGuardControlResponse(
            ok: ok,
            guardState: guardController.state.controlValue,
            displayMode: guardController.displayMode.controlValue,
            error: error
        )
        return (try? JSONEncoder().encode(response)) ?? Data()
    }

    private nonisolated static let callback: CFMessagePortCallBack = {
        _, _, data, info in
        guard let info, let data else { return nil }
        let server = Unmanaged<ControlServer>
            .fromOpaque(info)
            .takeUnretainedValue()
        let request = Data(data as Data)
        let response = MainActor.assumeIsolated {
            server.handle(request)
        }
        return Unmanaged.passRetained(response as CFData)
    }
}

private extension GuardState {
    var controlValue: String {
        switch self {
        case .inactive:
            return "inactive"
        case .guarding:
            return "guarding"
        case .authenticating:
            return "authenticating"
        case .restoringInput:
            return "restoringInput"
        case .recoveryFailed:
            return "recoveryFailed"
        }
    }
}

private extension DisplayMode {
    var controlValue: String {
        switch self {
        case .visible:
            return "visible"
        case .managedBlackout:
            return "blackout"
        }
    }
}
