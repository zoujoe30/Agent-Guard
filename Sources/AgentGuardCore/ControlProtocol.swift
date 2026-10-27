import Foundation

public enum AgentGuardControl {
    public static let portName = "com.local.agentguard.control"
    public static let messageID: Int32 = 1
}

public enum AgentGuardControlCommand: Equatable, Sendable {
    case status
    case display(DisplayMode)

    public init?(arguments: [String]) {
        switch arguments {
        case ["status"]:
            self = .status
        case ["display", "visible"]:
            self = .display(.visible)
        case ["display", "blackout"]:
            self = .display(.managedBlackout)
        default:
            return nil
        }
    }

    public init?(wireValue: String) {
        switch wireValue {
        case "status":
            self = .status
        case "display visible":
            self = .display(.visible)
        case "display blackout":
            self = .display(.managedBlackout)
        default:
            return nil
        }
    }

    public var wireValue: String {
        switch self {
        case .status:
            return "status"
        case .display(.visible):
            return "display visible"
        case .display(.managedBlackout):
            return "display blackout"
        }
    }
}

public struct AgentGuardControlResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let guardState: String
    public let displayMode: String
    public let error: String?

    public init(
        ok: Bool,
        guardState: String,
        displayMode: String,
        error: String? = nil
    ) {
        self.ok = ok
        self.guardState = guardState
        self.displayMode = displayMode
        self.error = error
    }

    public var summary: String {
        if let error {
            return "error=\(error)"
        }
        return "guard=\(guardState) display=\(displayMode)"
    }
}
