import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let guardController = GuardController()
    private lazy var controlServer = ControlServer(
        guardController: guardController
    )
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var powerStatusMenuItem: NSMenuItem!
    private var toggleMenuItem: NSMenuItem!
    private var activationMenuView: ActivationMenuItemView!
    private var authenticateMenuItem: NSMenuItem!
    private var visibleDisplayMenuItem: NSMenuItem!
    private var managedBlackoutMenuItem: NSMenuItem!
    private var lastMessage: String?
    private var retryDisplayMenuItem: NSMenuItem!
    private var excludedDisplaysMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        guardController.onStateChange = { [weak self] state, message in
            self?.lastMessage = message
            self?.updateUI(for: state)
            if let message, state == .inactive {
                self?.showNotification(message)
            }
        }
        if let error = guardController.recoverDisplaysOnLaunch() {
            lastMessage = error
        }
        guardController.prepareActivationShortcut()
        if let error = controlServer.start() {
            lastMessage = error
        }
        updateUI(for: guardController.state)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controlServer.stop()
        guardController.deactivate()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "lock.shield",
            accessibilityDescription: "Agent Guard"
        )

        let menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "状态：未启用", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        powerStatusMenuItem = NSMenuItem(
            title: "电源：防止电脑休眠，同时保持显示器常亮",
            action: nil,
            keyEquivalent: ""
        )
        powerStatusMenuItem.isEnabled = false
        menu.addItem(powerStatusMenuItem)
        excludedDisplaysMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        excludedDisplaysMenuItem.isEnabled = false
        menu.addItem(excludedDisplaysMenuItem)

        menu.addItem(.separator())

        toggleMenuItem = NSMenuItem(
            title: "",
            action: nil,
            keyEquivalent: ""
        )
        activationMenuView = ActivationMenuItemView()
        activationMenuView.onActivate = { [weak self] in
            self?.toggleGuard()
        }
        toggleMenuItem.view = activationMenuView
        menu.addItem(toggleMenuItem)

        authenticateMenuItem = NSMenuItem(
            title: "立即验证解除",
            action: #selector(authenticateNow),
            keyEquivalent: ""
        )
        authenticateMenuItem.target = self
        menu.addItem(authenticateMenuItem)
        retryDisplayMenuItem = NSMenuItem(title: "重试受管显示器恢复", action: #selector(retryDisplayRecovery), keyEquivalent: "")
        retryDisplayMenuItem.target = self
        menu.addItem(retryDisplayMenuItem)

        menu.addItem(.separator())

        let preventSystemSleepMenuItem = NSMenuItem(
            title: "托管期间自动防止电脑休眠",
            action: nil,
            keyEquivalent: ""
        )
        preventSystemSleepMenuItem.isEnabled = false
        preventSystemSleepMenuItem.state = .on
        menu.addItem(preventSystemSleepMenuItem)

        visibleDisplayMenuItem = NSMenuItem(
            title: "显示：保持常亮",
            action: #selector(selectVisibleDisplay),
            keyEquivalent: ""
        )
        visibleDisplayMenuItem.target = self
        menu.addItem(visibleDisplayMenuItem)

        managedBlackoutMenuItem = NSMenuItem(
            title: "显示：托管黑屏（受管外屏断开，Agent 使用内屏）",
            action: #selector(selectManagedBlackout),
            keyEquivalent: ""
        )
        managedBlackoutMenuItem.target = self
        menu.addItem(managedBlackoutMenuItem)
        let displayShortcutHint = NSMenuItem(
            title: "未托管时切换显示：右⌘ + G + S",
            action: nil, keyEquivalent: ""
        )
        displayShortcutHint.isEnabled = false
        menu.addItem(displayShortcutHint)

        menu.addItem(.separator())

        let permissionsItem = NSMenuItem(
            title: "检查并申请权限",
            action: #selector(requestPermissions),
            keyEquivalent: ""
        )
        permissionsItem.target = self
        menu.addItem(permissionsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 Agent Guard",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func updateUI(for state: GuardState) {
        if let button = statusItem.button, let window = button.window, let primary = NSScreen.screens.first {
            let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
            guardController.setRecoveryMenuRegion(CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY,
                                                         width: frame.width, height: frame.height))
        }
        let mode = guardController.displayMode == .visible ? "常亮" : "黑屏"
        let explanation: String
        switch state {
        case .inactive:
            explanation = "未托管，下次托管显示：\(mode)。右 Command＋G＋S 切换偏好。"
        case .guarding:
            explanation = "正在托管，显示模式：\(mode)。按实体空格键验证解除。"
        case .restoringInput:
            explanation = "认证已结束，正在恢复输入拦截；鼠标操作继续受限。"
        case .authenticating:
            explanation = "正在验证解除，显示恢复中或已恢复；托管显示偏好：\(mode)。"
        case .recoveryFailed:
            explanation = "显示或输入恢复异常，请打开菜单查看详情；托管显示偏好：\(mode)。"
        }
        if let button = statusItem.button {
            button.title = ""
            button.imagePosition = .imageOnly
            button.toolTip = "Agent Guard：" + explanation
                + (lastMessage.map { "\n" + $0 } ?? "")
            button.setAccessibilityLabel("Agent Guard：" + explanation)
        }
        let detail = lastMessage.map { "｜\($0)" } ?? ""
        statusMenuItem.title = "状态：\(state.statusText)\(detail)"
        powerStatusMenuItem.title = "电源：\(guardController.powerStatusText)"
        let excluded = Set((UserDefaults.standard.stringArray(forKey: "com.local.agentguard.excluded-display-uuids") ?? []).compactMap { UUID(uuidString: $0)?.uuidString })
        excludedDisplaysMenuItem.title = "排除托管的外屏：\(excluded.count) 台（不自动开关）"
        visibleDisplayMenuItem.state =
            guardController.displayMode == .visible ? .on : .off
        managedBlackoutMenuItem.state =
            guardController.displayMode == .managedBlackout ? .on : .off
        authenticateMenuItem.isHidden = state != .guarding && state != .recoveryFailed && state != .restoringInput
        retryDisplayMenuItem.isEnabled = state == .inactive || state == .recoveryFailed

        switch state {
        case .inactive:
            toggleMenuItem.view = activationMenuView
            toggleMenuItem.isEnabled = true
            statusItem.button?.image = NSImage(
                systemSymbolName: "lock.shield",
                accessibilityDescription: "Agent Guard 未启用"
            )
        case .guarding:
            toggleMenuItem.view = nil
            toggleMenuItem.title = "托管中（按实体空格键解除）"
            toggleMenuItem.isEnabled = false
            statusItem.button?.image = NSImage(
                systemSymbolName: "lock.shield.fill",
                accessibilityDescription: "Agent Guard 托管中"
            )
        case .restoringInput:
            toggleMenuItem.view = nil
            toggleMenuItem.title = "正在恢复输入拦截"
            toggleMenuItem.isEnabled = false
            statusItem.button?.image = NSImage(systemSymbolName: "exclamationmark.shield", accessibilityDescription: "正在恢复输入拦截")
        case .authenticating:
            toggleMenuItem.view = nil
            toggleMenuItem.title = "正在验证"
            toggleMenuItem.isEnabled = false
            statusItem.button?.image = NSImage(
                systemSymbolName: "touchid",
                accessibilityDescription: "Agent Guard 正在验证"
            )
        case .recoveryFailed:
            toggleMenuItem.view = nil
            toggleMenuItem.title = "托管恢复异常，请重试验证解除"
            toggleMenuItem.isEnabled = false
            statusItem.button?.image = NSImage(
                systemSymbolName: "exclamationmark.shield",
                accessibilityDescription: "Agent Guard 托管恢复异常"
            )
        }
        // Normal states encode the display preference inside the shield.
        // Authentication and recovery faults retain their dedicated symbols.
        if state == .inactive || state == .guarding {
            statusItem.button?.image = Self.displayShield(filled: state == .guarding, visible: guardController.displayMode == .visible)
        }
    }

    private static func displayShield(filled: Bool, visible: Bool) -> NSImage? {
        guard let shield = NSImage(systemSymbolName: filled ? "shield.fill" : "shield", accessibilityDescription: nil),
              let glyph = NSImage(systemSymbolName: visible ? "lightbulb.fill" : "lock.fill", accessibilityDescription: nil) else {
            return NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)
        }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            shield.draw(in: NSRect(x: 1, y: 0, width: 16, height: 18))
            glyph.draw(in: NSRect(x: 5.5, y: 5.25, width: 7, height: 8.5),
                      from: .zero, operation: filled ? .destinationOut : .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = true
        return image
    }

    private func showNotification(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Agent Guard"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    @objc private func toggleGuard() {
        if guardController.state == .inactive {
            guardController.activate()
        }
    }

    @objc private func retryDisplayRecovery() {
        guardController.retryDisplayRecovery()
    }

    @objc private func authenticateNow() {
        guardController.beginAuthentication()
    }

    @objc private func selectVisibleDisplay() {
        guardController.setDisplayMode(.visible)
        reopenStatusMenu()
    }

    @objc private func selectManagedBlackout() {
        guardController.setDisplayMode(.managedBlackout)
        reopenStatusMenu()
    }

    private func reopenStatusMenu() {
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.button?.performClick(nil)
        }
    }

    @objc private func requestPermissions() {
        let granted = guardController.requestPermissions(showPrompt: true)
        showNotification(
            granted
                ? "所需权限已授予。"
                : "权限尚未完整授予。请检查“辅助功能”和“输入监控”。"
        )
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
