import AppKit
import SwiftUI

private enum SpaceOverlayLayout {
    static let panelWidth: CGFloat = 252
    static let rowHeight: CGFloat = 40
    static let rowSpacing: CGFloat = 8
    static let outerPadding: CGFloat = 12
    static let rowHorizontalPadding: CGFloat = 12
    static let cornerRadius: CGFloat = 22
    static let rowCornerRadius: CGFloat = 14
    static let hoverActivationDistance: CGFloat = 1
    static let screenMargin: CGFloat = 10
    static let cursorAnchorX: CGFloat = 38
}

@MainActor
final class SpaceOverlayController {
    private struct PresentationContext {
        let snapshot: MenubarSpaceSnapshot
        let screen: NSScreen
        let screenIndex: Int
    }

    private let spaceSwitcher: SpaceSwitching
    private let titleResolver: SpaceTitleResolver
    private let viewModel = SpaceOverlayViewModel()
    private let hapticPerformer = NSHapticFeedbackManager.defaultPerformer

    private var panel: SpaceOverlayPanel?
    private var hostingView: NSHostingView<SpaceOverlayView>?
    private var mouseMonitor: Any?
    private var presentationContext: PresentationContext?
    private var openingMouseLocation = NSPoint.zero
    private var hasObservedMouseMovement = false

    init(
        spaceSwitcher: SpaceSwitching,
        titleResolver: SpaceTitleResolver
    ) {
        self.spaceSwitcher = spaceSwitcher
        self.titleResolver = titleResolver
    }

    func presentIfPossible() {
        guard presentationContext == nil else { return }
        guard let context = makePresentationContext() else { return }

        presentationContext = context
        openingMouseLocation = NSEvent.mouseLocation
        hasObservedMouseMovement = false
        viewModel.items = context.snapshot.spaces.enumerated().map { index, space in
            SpaceOverlayItem(
                id: index,
                title: titleResolver.title(for: space, spaceNumber: index + 1)
            )
        }
        viewModel.selectedIndex = context.snapshot.currentIndex

        let panel = ensurePanel()
        let size = panelSize(for: viewModel.items.count)
        panel.setContentSize(size)
        hostingView?.frame = NSRect(origin: .zero, size: size)
        panel.setFrame(
            panelFrame(
                for: size,
                on: context.screen,
                anchoredAt: openingMouseLocation,
                currentIndex: context.snapshot.currentIndex
            ),
            display: false
        )
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 1
        }

        installMouseMonitor()
    }

    func dismissWithoutSwitch() {
        dismiss(shouldCommitSelection: false)
    }

    func commitSelectionAndDismiss() {
        dismiss(shouldCommitSelection: true)
    }

    private func dismiss(shouldCommitSelection: Bool) {
        guard let context = presentationContext else { return }

        if shouldCommitSelection,
           let selectedIndex = viewModel.selectedIndex,
           selectedIndex != context.snapshot.currentIndex {
            _ = spaceSwitcher.switchToSpace(selectedIndex + 1, onScreen: context.screenIndex)
        }

        removeMouseMonitor()
        panel?.orderOut(nil)
        panel?.alphaValue = 1
        presentationContext = nil
        hasObservedMouseMovement = false
    }

    private func ensurePanel() -> SpaceOverlayPanel {
        if let panel {
            return panel
        }

        let initialSize = panelSize(for: 1)
        let panel = SpaceOverlayPanel(
            contentRect: NSRect(origin: .zero, size: initialSize)
        )
        let hostingView = NSHostingView(
            rootView: SpaceOverlayView(viewModel: viewModel)
        )
        hostingView.frame = NSRect(origin: .zero, size: initialSize)
        panel.contentView = hostingView

        self.panel = panel
        self.hostingView = hostingView
        return panel
    }

    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateSelectionForCurrentMouseLocation()
            }
        }
    }

    private func removeMouseMonitor() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        mouseMonitor = nil
    }

    private func updateSelectionForCurrentMouseLocation() {
        guard let panel, let context = presentationContext else { return }

        let mouseLocation = NSEvent.mouseLocation
        if !hasObservedMouseMovement {
            let distance = hypot(
                mouseLocation.x - openingMouseLocation.x,
                mouseLocation.y - openingMouseLocation.y
            )
            guard distance >= SpaceOverlayLayout.hoverActivationDistance else {
                return
            }
            hasObservedMouseMovement = true
        }

        let localPoint = NSPoint(
            x: mouseLocation.x - panel.frame.minX,
            y: mouseLocation.y - panel.frame.minY
        )
        guard let contentView = panel.contentView,
              contentView.bounds.contains(localPoint) else {
            return
        }

        guard let hoveredIndex = hoveredRowIndex(
            at: localPoint,
            rowCount: context.snapshot.spaceCount,
            panelHeight: contentView.bounds.height
        ) else {
            return
        }

        guard viewModel.selectedIndex != hoveredIndex else {
            return
        }

        viewModel.selectedIndex = hoveredIndex
        performHoverHaptic()
    }

    private func hoveredRowIndex(
        at point: NSPoint,
        rowCount: Int,
        panelHeight: CGFloat
    ) -> Int? {
        let rowWidth = SpaceOverlayLayout.panelWidth - (SpaceOverlayLayout.outerPadding * 2)

        for index in 0..<rowCount {
            let rowRect = NSRect(
                x: SpaceOverlayLayout.outerPadding,
                y: panelHeight
                    - SpaceOverlayLayout.outerPadding
                    - SpaceOverlayLayout.rowHeight
                    - CGFloat(index) * (SpaceOverlayLayout.rowHeight + SpaceOverlayLayout.rowSpacing),
                width: rowWidth,
                height: SpaceOverlayLayout.rowHeight
            )

            if rowRect.contains(point) {
                return index
            }
        }

        return nil
    }

    private func makePresentationContext() -> PresentationContext? {
        guard let snapshot = spaceSwitcher.cursorSnapshot(),
              snapshot.spaceCount > 0 else {
            return nil
        }

        let mouseLocation = NSEvent.mouseLocation
        guard let screenIndex = NSScreen.screens.firstIndex(where: { $0.frame.contains(mouseLocation) }) else {
            return nil
        }

        return PresentationContext(
            snapshot: snapshot,
            screen: NSScreen.screens[screenIndex],
            screenIndex: screenIndex
        )
    }

    private func panelSize(for itemCount: Int) -> NSSize {
        let rowCount = max(itemCount, 1)
        let height = SpaceOverlayLayout.outerPadding * 2
            + CGFloat(rowCount) * SpaceOverlayLayout.rowHeight
            + CGFloat(max(rowCount - 1, 0)) * SpaceOverlayLayout.rowSpacing

        return NSSize(width: SpaceOverlayLayout.panelWidth, height: height)
    }

    private func panelFrame(
        for size: NSSize,
        on screen: NSScreen,
        anchoredAt cursorLocation: NSPoint,
        currentIndex: Int
    ) -> NSRect {
        let visibleFrame = screen.visibleFrame
        let minX = visibleFrame.minX + SpaceOverlayLayout.screenMargin
        let maxX = visibleFrame.maxX - size.width - SpaceOverlayLayout.screenMargin
        let minY = visibleFrame.minY + SpaceOverlayLayout.screenMargin
        let maxY = visibleFrame.maxY - size.height - SpaceOverlayLayout.screenMargin

        let currentRowCenterY = size.height
            - SpaceOverlayLayout.outerPadding
            - (SpaceOverlayLayout.rowHeight / 2)
            - CGFloat(currentIndex) * (SpaceOverlayLayout.rowHeight + SpaceOverlayLayout.rowSpacing)

        let preferredX = cursorLocation.x - SpaceOverlayLayout.cursorAnchorX
        let preferredY = cursorLocation.y - currentRowCenterY

        return NSRect(
            x: min(max(preferredX, minX), maxX),
            y: min(max(preferredY, minY), maxY),
            width: size.width,
            height: size.height
        )
    }

    private func performHoverHaptic() {
        hapticPerformer.perform(.levelChange, performanceTime: .default)
    }
}

@MainActor
private final class SpaceOverlayViewModel: ObservableObject {
    @Published var items: [SpaceOverlayItem] = []
    @Published var selectedIndex: Int?
}

private struct SpaceOverlayItem: Identifiable {
    let id: Int
    let title: String
}

private struct SpaceOverlayView: View {
    @ObservedObject var viewModel: SpaceOverlayViewModel

    var body: some View {
        VStack(spacing: SpaceOverlayLayout.rowSpacing) {
            ForEach(viewModel.items.indices, id: \.self) { index in
                let item = viewModel.items[index]

                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.96))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SpaceOverlayLayout.rowHorizontalPadding)
                    .frame(height: SpaceOverlayLayout.rowHeight)
                    .background(rowBackground(isSelected: viewModel.selectedIndex == index))
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: SpaceOverlayLayout.rowCornerRadius,
                            style: .continuous
                        )
                    )
            }
        }
        .padding(SpaceOverlayLayout.outerPadding)
        .frame(width: SpaceOverlayLayout.panelWidth)
        .background(
            RoundedRectangle(cornerRadius: SpaceOverlayLayout.cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SpaceOverlayLayout.cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 22, y: 10)
    }

    @ViewBuilder
    private func rowBackground(isSelected: Bool) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: SpaceOverlayLayout.rowCornerRadius, style: .continuous)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: SpaceOverlayLayout.rowCornerRadius, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SpaceOverlayLayout.rowCornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.28), lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: SpaceOverlayLayout.rowCornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.08))
        }
    }
}

private final class SpaceOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [
            .fullScreenAuxiliary,
            .ignoresCycle,
            .moveToActiveSpace,
            .transient
        ]
    }
}
