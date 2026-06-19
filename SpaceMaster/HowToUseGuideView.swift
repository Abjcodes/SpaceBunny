import AppKit

final class HowToUseGuideView: NSView {
    private enum Layout {
        static let width: CGFloat = 320
        static let height: CGFloat = 310
        static let cornerRadius: CGFloat = 8
        static let horizontalInset: CGFloat = 16
        static let verticalInset: CGFloat = 14
    }

    private static let bulletPoints = [
        "Grant Accessibility Permission so SpaceBunny can switch spaces.",
        "Use the menu bar to see your current desktop or full-screen app.",
        "Open the menu and pick any numbered space to jump there.",
        "Keep 4-Finger Instant Swipe enabled to switch spaces with a fast trackpad swipe.",
        "Rename the current space to easily remember the spaces.",
        "Assign a modifier + key hotkey for any space to instantly switch to that space.",
        "Tap Refresh if a recent macOS space change is not reflected yet.",
        "Click on left option + s to move to the next space and option + a to move to the previous space.",
        "Hold the same key combination to cycle through spaces."
    ]

    private let bulletStackView = NSStackView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.height))

        configureView()
        configureBulletStackView()
        configureLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Layout.width, height: Layout.height)
    }

    private func configureView() {
        wantsLayer = true
        layer?.cornerRadius = Layout.cornerRadius
        layer?.borderWidth = 1
        updateLayerColors()
    }

    private func updateLayerColors() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    private func configureBulletStackView() {
        bulletStackView.orientation = .vertical
        bulletStackView.alignment = .leading
        bulletStackView.spacing = 9
        bulletStackView.translatesAutoresizingMaskIntoConstraints = false

        Self.bulletPoints.forEach { point in
            let label = NSTextField(labelWithString: "• \(point)")
            label.font = .systemFont(ofSize: 13, weight: .regular)
            label.textColor = .labelColor
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            label.translatesAutoresizingMaskIntoConstraints = false
            bulletStackView.addArrangedSubview(label)

            NSLayoutConstraint.activate([
                label.widthAnchor.constraint(equalTo: bulletStackView.widthAnchor)
            ])
        }
    }

    private func configureLayout() {
        addSubview(bulletStackView)

        NSLayoutConstraint.activate([
            bulletStackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.horizontalInset),
            bulletStackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.horizontalInset),
            bulletStackView.topAnchor.constraint(equalTo: topAnchor, constant: Layout.verticalInset),
            bulletStackView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Layout.verticalInset)
        ])
    }
}
