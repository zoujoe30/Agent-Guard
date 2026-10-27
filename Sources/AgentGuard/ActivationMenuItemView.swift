import AppKit

@MainActor
final class ActivationMenuItemView: NSView {
    var onActivate: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "进入 Agent 托管模式")
    private let modifierLabel = NSTextField(labelWithString: "右⌘")
    private let keyLabel = NSTextField(labelWithString: "G")
    private var isHovered = false {
        didSet {
            updateColors()
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayout()
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel("进入 Agent 托管模式")
        setAccessibilityHelp("快捷键 右 Command-G")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        onActivate?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHovered else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 5, dy: 1),
            xRadius: 5,
            yRadius: 5
        ).fill()
    }

    private func configureLayout() {
        frame = NSRect(x: 0, y: 0, width: 385, height: 24)

        let menuFont = NSFont.menuFont(ofSize: 0)
        titleLabel.font = menuFont
        modifierLabel.font = menuFont
        keyLabel.font = menuFont

        [titleLabel, modifierLabel, keyLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: modifierLabel.leadingAnchor,
                constant: -20
            ),
            // Match AppKit's native key-equivalent column. Pixel validation
            // against the enabled Command-Q item gives a 17-point inset.
            keyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -17),
            keyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            modifierLabel.trailingAnchor.constraint(equalTo: keyLabel.leadingAnchor, constant: -4),
            modifierLabel.centerYAnchor.constraint(equalTo: keyLabel.centerYAnchor)
        ])

        updateColors()
    }

    private func updateColors() {
        let primaryColor: NSColor = isHovered ? .selectedMenuItemTextColor : .labelColor
        let shortcutColor: NSColor = isHovered
            ? .selectedMenuItemTextColor
            : .secondaryLabelColor
        titleLabel.textColor = primaryColor
        modifierLabel.textColor = shortcutColor
        keyLabel.textColor = shortcutColor
    }
}
