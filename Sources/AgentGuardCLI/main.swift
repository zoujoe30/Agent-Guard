import AgentGuardCore
import CoreFoundation
import Darwin
import Foundation

private let usage = """
usage:
  agent-guard status
  agent-guard display visible
  agent-guard display blackout
"""

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = AgentGuardControlCommand(arguments: arguments) else {
    fputs("\(usage)\n", stderr)
    exit(EXIT_FAILURE)
}

guard let port = CFMessagePortCreateRemote(
    kCFAllocatorDefault,
    AgentGuardControl.portName as CFString
) else {
    fputs("Agent Guard is not running or its control interface is unavailable.\n", stderr)
    exit(EXIT_FAILURE)
}

let requestData = Data(command.wireValue.utf8) as CFData
var responseData: Unmanaged<CFData>?
let result = CFMessagePortSendRequest(
    port,
    AgentGuardControl.messageID,
    requestData,
    2,
    2,
    CFRunLoopMode.defaultMode.rawValue,
    &responseData
)

guard
    result == kCFMessagePortSuccess,
    let responseData
else {
    fputs("Agent Guard control request failed: \(result)\n", stderr)
    exit(EXIT_FAILURE)
}

let data = responseData.takeRetainedValue() as Data
guard let response = try? JSONDecoder().decode(
    AgentGuardControlResponse.self,
    from: data
) else {
    fputs("Agent Guard returned an invalid response.\n", stderr)
    exit(EXIT_FAILURE)
}

if response.ok {
    print(response.summary)
    exit(EXIT_SUCCESS)
}

fputs("\(response.summary)\n", stderr)
exit(EXIT_FAILURE)
