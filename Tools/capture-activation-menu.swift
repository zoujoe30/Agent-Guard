import AppKit
import Darwin

@main
struct CaptureActivationMenu {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        let menu = NSMenu()
        let status = NSMenuItem(title: "状态：未启用", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let power = NSMenuItem(
            title: "电源：防止电脑休眠，同时保持显示器常亮",
            action: nil,
            keyEquivalent: ""
        )
        power.isEnabled = false
        menu.addItem(power)
        menu.addItem(.separator())

        let activationItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        activationItem.view = ActivationMenuItemView()
        menu.addItem(activationItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 Agent Guard", action: nil, keyEquivalent: "q"))

        let targetScreen = NSScreen.screens.dropFirst().first ?? NSScreen.main!
        let popupPoint = NSPoint(x: targetScreen.visibleFrame.midX, y: targetScreen.visibleFrame.midY)
        print("READY pid=\(getpid()) screen=\(targetScreen.localizedName)")
        fflush(stdout)

        application.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            menu.cancelTracking()
            application.terminate(nil)
        }
        DispatchQueue.main.async {
            menu.popUp(positioning: nil, at: popupPoint, in: nil)
        }
        application.run()
    }
}
