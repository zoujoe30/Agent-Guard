import AppKit

if KeyboardBacklightController.runIfRequested() { exit(0) }

if DisplayRecoveryWatchdog.runIfRequested() { exit(0) }

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
