import AppKit
import SwiftUI

final class MenuBarPanelWindow<Content: View>: NSPanel {
    private let content: () -> Content

    private let maxPanelHeight: CGFloat = 820

    private lazy var visualEffectView: NSView = {
        if #available(macOS 26.0, *) {
            let view = NSGlassEffectView()
            view.style = .regular
            view.cornerRadius = 18
            view.translatesAutoresizingMaskIntoConstraints = true
            return view
        } else {
            let view = NSVisualEffectView()
            view.blendingMode = .behindWindow
            view.state = .active
            view.material = .popover
            view.wantsLayer = true
            view.layer?.cornerCurve = .continuous
            view.layer?.cornerRadius = 18
            view.translatesAutoresizingMaskIntoConstraints = true
            return view
        }
    }()

    private var rootView: some View {
        content()
            .modifier(RootViewModifier(windowTitle: title))
            .onSizeUpdate { [weak self] size in
                self?.contentSizeDidUpdate(to: size)
            }
    }

    private lazy var hostingView: NSHostingView<some View> = {
        let view = NSHostingView(rootView: rootView)
        if #available(macOS 13.0, *) {
            view.sizingOptions = []
        }
        view.isVerticalContentSizeConstraintActive = false
        view.isHorizontalContentSizeConstraintActive = false
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    init(title: String, content: @escaping () -> Content) {
        self.content = content

        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 640),
            styleMask: [.titled, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.title = title

        isMovable = false
        isMovableByWindowBackground = false
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        animationBehavior = .none
        if #available(macOS 13.0, *) {
            collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
        } else {
            collectionBehavior = [.stationary, .moveToActiveSpace, .fullScreenAuxiliary]
        }

        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        contentView = visualEffectView
        visualEffectView.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
        ])
    }

    private func contentSizeDidUpdate(to rawSize: CGSize) {
        let size = CGSize(width: rawSize.width, height: min(rawSize.height, maxPanelHeight))

        var nextFrame = frame
        let previousContentSize = contentRect(forFrameRect: frame).size

        let deltaX = size.width - previousContentSize.width
        let deltaY = size.height - previousContentSize.height

        nextFrame.origin.y -= deltaY
        nextFrame.size.width += deltaX
        nextFrame.size.height += deltaY

        guard frame != nextFrame else { return }

        DispatchQueue.main.async { [weak self] in
            self?.setFrame(nextFrame, display: true, animate: true)
        }
    }
}
