import AppKit
import Observation
import SwiftUI
import AIUsageMeterCore

@MainActor
final class MenuBarPanelController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let statusItem: NSStatusItem
    private let appState: AppState
    private let themeManager: ThemeManager

    private var localEventMonitor: EventMonitor?
    private var globalEventMonitor: EventMonitor?
    private var appearanceObservation: NSKeyValueObservation?
    private var defaultsObserver: NSObjectProtocol?
    /// Ticks at 5 Hz only while an agent is consuming, to pulse its cell.
    private var animationTimer: Timer?
    private let renderGate = MenuBarRenderGate()

    init(title: String, appState: AppState, themeManager: ThemeManager) {
        self.appState = appState
        self.themeManager = themeManager

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        // macOS 26: autosaveName must be set in a separate async dispatch
        DispatchQueue.main.async { [weak statusItem] in
            statusItem?.autosaveName = "TokenBurnMain"
        }

        let panel = MenuBarPanelWindow(title: title) {
            ContentView(appState: appState)
        }
        self.window = panel

        super.init()

        // Set empty image first (not nil), then update with real icon
        statusItem.button?.image = NSImage()
        statusItem.button?.setAccessibilityTitle(title)
        updateStatusItemImageIfNeeded(force: true)

        localEventMonitor = LocalEventMonitor(mask: [.leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            if let button = self.statusItem.button,
               event.window == button.window,
               !event.modifierFlags.contains(.command) {
                self.didPressStatusBarButton(button)
                return nil
            }
            return event
        }

        globalEventMonitor = GlobalEventMonitor(mask: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            guard self.window.isVisible else { return }

            // Only dismiss when clicking outside the panel. Global monitors see all clicks, including those
            // inside our own window; without this check, buttons inside the panel become unclickable.
            let mouseLocation = NSEvent.mouseLocation
            if self.window.frame.contains(mouseLocation) {
                return
            }

            if self.window.isKeyWindow {
                self.window.resignKey()
            }
        }

        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in
                self?.updateStatusItemImageIfNeeded(force: true)
            }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: AppDefaults.userDefaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateStatusItemImageIfNeeded() }
        }

        window.delegate = self
        localEventMonitor?.start()

        startIconObservationLoop()
        syncAnimationTimer()

        autoOpenMenuBarLegendPanelIfNeeded()
    }

    deinit {
        animationTimer?.invalidate()
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func startIconObservationLoop() {
        withObservationTracking {
            // Touch all properties that affect the icon so Observation knows
            // what to watch. The actual diff is done via IconSnapshot below.
            _ = appState.isRefreshing
            _ = appState.lastRefreshDate
            _ = appState.menuBarNeedsRedraw
            _ = themeManager.current.menuBar
            for service in appState.services {
                _ = service.config.isEnabled
                _ = service.usagePercentage
                _ = service.fiveHourUsage
                _ = service.sevenDayUsage
                _ = service.isConsuming
            }
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.onObservedStateChanged()
            }
        }
    }

    /// Called once per observation change batch. Diffs against the last
    /// snapshot to avoid redundant icon renders.
    private func onObservedStateChanged() {
        updateStatusItemImageIfNeeded()
        syncAnimationTimer()

        startIconObservationLoop()
    }

    private func updateStatusItemImageIfNeeded(force: Bool = false) {
        let now = Date()
        guard renderGate.shouldRender(appState: appState, themeManager: themeManager,
                                      at: now, force: force) else { return }
        let image = MenuBarIconRenderer.render(appState: appState, themeManager: themeManager,
                                               animationDate: now)
        statusItem.button?.image = image
        statusItem.button?.title = ""
        statusItem.button?.imagePosition = .imageOnly
    }

    /// Runs the pulse only while some cell's agent is consuming. Ticks go
    /// through the render gate, so frames between beats cost nothing.
    private func syncAnimationTimer() {
        let consuming = ServiceType.allCases.contains {
            appState.menuBarRepresentative(for: $0)?.isConsuming == true
        }
        if consuming, animationTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateStatusItemImageIfNeeded() }
            }
            timer.tolerance = 0.05
            animationTimer = timer
        } else if !consuming, let timer = animationTimer {
            timer.invalidate()
            animationTimer = nil
            updateStatusItemImageIfNeeded()
        }
    }

    private func didPressStatusBarButton(_ sender: NSStatusBarButton) {
        if window.isVisible {
            dismissWindow()
            return
        }

        setWindowPosition()

        DistributedNotificationCenter.default().post(name: .beginMenuTracking, object: nil)
        window.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        globalEventMonitor?.start()
        statusItem.button?.highlight(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        globalEventMonitor?.stop()
        dismissWindow()
    }

    private func dismissWindow() {
        DistributedNotificationCenter.default().post(name: .endMenuTracking, object: nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // AppKit runs animation completion handlers on the main queue, but
            // Swift's concurrency checker sees a nonisolated Sendable closure
            // here — hop back onto the main actor explicitly so we can touch
            // MainActor-isolated properties without warnings.
            Task { @MainActor in
                self?.window.orderOut(nil)
                self?.window.alphaValue = 1
                self?.statusItem.button?.highlight(false)
            }
        }
    }

    private func setWindowPosition() {
        guard let statusItemWindow = statusItem.button?.window else {
            window.center()
            return
        }

        var targetRect = statusItemWindow.frame

        if let screen = statusItemWindow.screen {
            let windowWidth = window.frame.width
            if statusItemWindow.frame.origin.x + windowWidth > screen.visibleFrame.width {
                targetRect.origin.x += statusItemWindow.frame.width
                targetRect.origin.x -= windowWidth
                targetRect.origin.x += Metrics.windowBorderSize
            } else {
                targetRect.origin.x -= Metrics.windowBorderSize
            }
        } else {
            targetRect.origin.x -= Metrics.windowBorderSize
        }

        window.setFrameTopLeftPoint(targetRect.origin)
    }

    private func autoOpenMenuBarLegendPanelIfNeeded() {
        guard appState.showMenuBarLegendOnboarding else { return }
        guard !AppDefaults.userDefaults.bool(forKey: OnboardingDefaults.didAutoOpenMenuBarLegendPanel) else { return }

        AppDefaults.userDefaults.set(true, forKey: OnboardingDefaults.didAutoOpenMenuBarLegendPanel)
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 600_000_000)

            for _ in 0..<12 {
                if self.window.isVisible { return }
                if let button = self.statusItem.button, button.window != nil {
                    self.didPressStatusBarButton(button)
                    return
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    // MARK: - Dev Snapshot

    /// When `AIM_SNAPSHOT_ONBOARDING_PATH` is set, we render the current panel UI to a PNG file.
    /// This avoids Screen Recording permission issues (no OS-level screenshot APIs).
    func debugSnapshotOnboardingPNG(to url: URL) async {
        appState.showMenuBarLegendOnboarding = true

        if !window.isVisible {
            setWindowPosition()
            window.makeKeyAndOrderFront(nil)
        }

        // Wait for the window to lay out, and for the overlay spring animation to settle.
        try? await Task.sleep(nanoseconds: 900_000_000)

        do {
            try snapshotPanelPNG(to: url)
        } catch {
            print("❌ Snapshot failed: \(error)")
        }
    }

    private func snapshotPanelPNG(to url: URL) throws {
        guard let contentView = window.contentView else {
            throw NSError(domain: "AIUsageMeter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing window.contentView"])
        }

        contentView.layoutSubtreeIfNeeded()

        let bounds = contentView.bounds
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw NSError(domain: "AIUsageMeter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create bitmap rep"])
        }

        contentView.cacheDisplay(in: bounds, to: rep)

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "AIUsageMeter", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
        }

        try data.write(to: url, options: .atomic)
        print("📸 Snapshot written: \(url.path)")
    }
}

private extension Notification.Name {
    static let beginMenuTracking = Notification.Name("com.apple.HIToolbox.beginMenuTrackingNotification")
    static let endMenuTracking = Notification.Name("com.apple.HIToolbox.endMenuTrackingNotification")
}

private enum Metrics {
    static let windowBorderSize: CGFloat = 2
}
