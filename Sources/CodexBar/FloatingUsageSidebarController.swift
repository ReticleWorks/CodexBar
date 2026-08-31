import AppKit
import CodexBarCore
import Observation
import SwiftUI

enum FloatingSidebarSnapshotResolver {
    static func snapshot(
        for provider: UsageProvider,
        providerSnapshot: UsageSnapshot?,
        claudeAccounts: [ProviderAccountUsageSnapshot]) -> UsageSnapshot?
    {
        if provider == .claude,
           let activeSubscription = claudeAccounts.first(where: \.isActive)?.snapshot
        {
            return activeSubscription
        }
        return providerSnapshot
    }
}

struct FloatingUsageMetric: Equatable {
    let usedPercent: Double
    let displayedPercent: Double
    let showsUsed: Bool

    var directionLabel: String {
        self.showsUsed ? "used" : "remaining"
    }

    var compactPercent: String {
        if self.showsUsed, self.usedPercent >= 1000 {
            return "\(Int((self.usedPercent / 100).rounded()))x"
        }
        return "\(Int(self.displayedPercent.rounded()))%"
    }

    var ringFraction: Double {
        min(1, max(0, self.displayedPercent / 100))
    }

    static func resolve(window: RateWindow?, showsUsed: Bool) -> Self? {
        guard let window else { return nil }
        let usedPercent = max(0, window.usedPercent)
        let displayedPercent = showsUsed ? usedPercent : max(0, 100 - usedPercent)
        return Self(
            usedPercent: usedPercent,
            displayedPercent: displayedPercent,
            showsUsed: showsUsed)
    }

    static func mostConstrainedWindow(_ windows: [RateWindow?]) -> RateWindow? {
        windows.compactMap(\.self).max { $0.usedPercent < $1.usedPercent }
    }
}

enum FloatingSidebarMetricResolver {
    static func metric(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        showsUsed: Bool) -> FloatingUsageMetric?
    {
        guard let snapshot else { return nil }
        let semantic = ProviderDescriptorRegistry.descriptor(for: provider)
            .presentation.semanticWindows(snapshot: snapshot)
        var candidates: [RateWindow?] = [
            semantic.session,
            semantic.weekly,
            snapshot.primary,
            snapshot.secondary,
            snapshot.tertiary,
        ]
        // Claude model pools and Amp pools are quota lanes. Codex extras are Spark lanes,
        // which this local package deliberately never surfaces.
        if provider != .codex {
            candidates.append(contentsOf: snapshot.extraRateWindows?.map(\.window) ?? [])
        }
        return FloatingUsageMetric.resolve(
            window: FloatingUsageMetric.mostConstrainedWindow(candidates),
            showsUsed: showsUsed)
    }
}

enum FloatingSidebarGeometry {
    static let trailingMargin: CGFloat = 0
    static let tuckedWidth: CGFloat = 10
    static let edgeTriggerWidth: CGFloat = tuckedWidth

    static func shownOrigin(
        screen: NSRect,
        panelSize: NSSize,
        preferredY: CGFloat?) -> NSPoint
    {
        let minimumY = screen.minY
        let maximumY = max(minimumY, screen.maxY - panelSize.height)
        let centeredY = screen.midY - panelSize.height / 2
        return NSPoint(
            x: screen.maxX - panelSize.width - self.trailingMargin,
            y: min(max(preferredY ?? centeredY, minimumY), maximumY))
    }

    static func hiddenOrigin(screen: NSRect, shownOrigin: NSPoint) -> NSPoint {
        NSPoint(x: screen.maxX - self.tuckedWidth, y: shownOrigin.y)
    }

    static func pointerTouchesTrailingEdge(_ pointer: NSPoint, screen: NSRect) -> Bool {
        screen.contains(pointer) && pointer.x >= screen.maxX - self.edgeTriggerWidth
    }
}

@MainActor
@Observable
final class FloatingSidebarPresentation {
    var isTucked = true
    var isAccountPickerOpen = false
    var maximumContentHeight: CGFloat = 720
    @ObservationIgnored var requestReveal: (() -> Void)?
    @ObservationIgnored var requestResize: (@MainActor (CGSize) -> Void)?

    var keepsOpen: Bool {
        self.isAccountPickerOpen
    }
}

enum FloatingSidebarLayout {
    static let panelWidth: CGFloat = 270
    static let sidebarWidth: CGFloat = 64
    static let providerRowHeight: CGFloat = 69
    static let settingsHeight: CGFloat = 48
    static let defaultPanelHeight: CGFloat = 200
    static let minimumPanelHeight: CGFloat = 160
    static let maximumPanelHeight: CGFloat = 760
}

@MainActor
final class FloatingUsageSidebarController {
    private nonisolated static let originKey = "LocalSpendTrackerFloatingPillOrigin"

    private let settings: SettingsStore
    private let store: UsageStore
    private let panel: NSPanel
    private let hostingController: NSHostingController<FloatingUsagePillView>
    private let presentation = FloatingSidebarPresentation()
    private var isObserving = false
    private var didSizeAndPosition = false
    private var moveObserver: NSObjectProtocol?
    private var pointerTimer: Timer?
    private var hideWorkItem: DispatchWorkItem?
    private var isRevealed = false
    private var isProgrammaticMove = false
    private var activeScreen: NSScreen?

    init(
        store: UsageStore,
        settings: SettingsStore,
        openProvider: @escaping @MainActor (UsageProvider) -> Void,
        openSettings: @escaping @MainActor () -> Void,
        accountProjection: FloatingSidebarAccountProjection? = nil)
    {
        self.store = store
        self.settings = settings
        self.panel = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: FloatingSidebarLayout.panelWidth,
                height: FloatingSidebarLayout.defaultPanelHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false)
        let resolvedAccountProjection: FloatingSidebarAccountProjection = accountProjection
            ?? { provider in store.accountProjection(for: provider) }
        self.hostingController = NSHostingController(rootView: FloatingUsagePillView(
            store: store,
            settings: settings,
            presentation: self.presentation,
            accountProjection: resolvedAccountProjection,
            openProvider: openProvider,
            openSettings: openSettings))

        self.panel.identifier = NSUserInterfaceItemIdentifier("floatingUsageSidebar")
        self.panel.level = .statusBar
        self.panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.panel.isMovableByWindowBackground = false
        self.panel.acceptsMouseMovedEvents = true
        self.panel.becomesKeyOnlyIfNeeded = false
        self.panel.isOpaque = false
        self.panel.backgroundColor = .clear
        // The SwiftUI shadow follows the pill. An AppKit shadow would reveal the rectangular panel.
        self.panel.hasShadow = false
        self.panel.hidesOnDeactivate = false
        // Window restoration can move the pill to a different display after we have
        // placed it at the pointer's edge. The controller persists only its vertical position.
        self.panel.isRestorable = false

        self.hostingController.sizingOptions = [.preferredContentSize]
        self.hostingController.view.wantsLayer = true
        self.hostingController.view.layer?.backgroundColor = .clear
        self.panel.contentViewController = self.hostingController
        self.presentation.requestReveal = { [weak self] in
            guard let self,
                  let screen = self.screen(containing: NSEvent.mouseLocation)
                    ?? self.activeScreen
                    ?? NSScreen.main
            else { return }
            self.reveal(on: screen)
        }
        self.presentation.requestResize = { [weak self] size in
            self?.resizePanel(to: size)
        }
    }

    func start() {
        self.observeMoves()
        self.observePointer()
        self.observeVisibility()
        self.applyVisibility()
    }

    func stop() {
        self.isObserving = false
        self.hideWorkItem?.cancel()
        self.hideWorkItem = nil
        self.pointerTimer?.invalidate()
        self.pointerTimer = nil
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
            self.moveObserver = nil
        }
        self.panel.orderOut(nil)
        self.panel.close()
    }

    private func observeVisibility() {
        self.isObserving = true
        withObservationTracking {
            _ = self.settings.floatingSidebarEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isObserving else { return }
                self.applyVisibility()
                self.observeVisibility()
            }
        }
    }

    private func applyVisibility() {
        if self.settings.floatingSidebarEnabled {
            if !self.didSizeAndPosition {
                self.panel.alphaValue = 0
            }
            self.panel.orderFrontRegardless()
            self.sizeAndPositionIfNeeded()
            self.conceal(animated: false)
        } else {
            self.hideWorkItem?.cancel()
            self.isRevealed = false
            self.panel.orderOut(nil)
        }
    }

    private func sizeAndPositionIfNeeded() {
        guard !self.didSizeAndPosition else { return }
        var size = self.hostingController.view.fittingSize
        if size.width < 1 || size.height < 1 {
            size = NSSize(
                width: FloatingSidebarLayout.panelWidth,
                height: FloatingSidebarLayout.defaultPanelHeight)
        }
        let savedY = UserDefaults.standard.string(forKey: Self.originKey).map(NSPointFromString)?.y
        let screen = self.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main
        self.activeScreen = screen
        if let screen {
            self.presentation.maximumContentHeight = self.maximumPanelHeight(for: screen)
            size.width = FloatingSidebarLayout.panelWidth
            size.height = min(size.height, self.presentation.maximumContentHeight)
        }
        self.panel.setContentSize(size)
        self.didSizeAndPosition = true
        if let screen {
            let origin = FloatingSidebarGeometry.shownOrigin(
                screen: screen.visibleFrame,
                panelSize: size,
                preferredY: savedY)
            self.setPanelOrigin(origin)
        }
        self.panel.alphaValue = 1
    }

    private func maximumPanelHeight(for screen: NSScreen) -> CGFloat {
        min(
            FloatingSidebarLayout.maximumPanelHeight,
            max(FloatingSidebarLayout.minimumPanelHeight, screen.visibleFrame.height - 32))
    }

    private func resizePanel(to measuredSize: CGSize) {
        guard self.didSizeAndPosition,
              measuredSize.width > 1,
              measuredSize.height > 1,
              let screen = self.activeScreen ?? NSScreen.main
        else { return }

        let maximumHeight = self.maximumPanelHeight(for: screen)
        self.presentation.maximumContentHeight = maximumHeight
        let size = NSSize(
            width: FloatingSidebarLayout.panelWidth,
            height: min(measuredSize.height, maximumHeight))
        guard abs((self.panel.contentView?.frame.height ?? 0) - size.height) > 0.5 else { return }

        let shown = FloatingSidebarGeometry.shownOrigin(
            screen: screen.visibleFrame,
            panelSize: size,
            preferredY: self.panel.frame.minY)
        let origin = self.presentation.isTucked
            ? FloatingSidebarGeometry.hiddenOrigin(screen: screen.frame, shownOrigin: shown)
            : shown
        self.panel.setContentSize(size)
        self.setPanelOrigin(origin)
    }

    private func observeMoves() {
        guard self.moveObserver == nil else { return }
        self.moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: self.panel,
            queue: .main)
        { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRevealed, !self.isProgrammaticMove else { return }
                UserDefaults.standard.set(NSStringFromPoint(self.panel.frame.origin), forKey: Self.originKey)
            }
        }
    }

    private func observePointer() {
        guard self.pointerTimer == nil else { return }
        // Polling avoids Accessibility permission and works across all Spaces and displays.
        // Global mouse monitors can be suppressed by macOS privacy state, leaving an
        // auto-hidden panel with no way to reveal it.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handlePointerMovement()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.pointerTimer = timer
        MenuSwitchFlickerProbe.debugLog("floating-sidebar pointer timer started")
    }

    private func handlePointerMovement() {
        guard self.settings.floatingSidebarEnabled else { return }
        let pointer = NSEvent.mouseLocation
        if let touchedScreen = self.screen(containing: pointer),
           FloatingSidebarGeometry.pointerTouchesTrailingEdge(pointer, screen: touchedScreen.frame)
        {
            self.reveal(on: touchedScreen)
            return
        }

        if self.presentation.keepsOpen {
            self.hideWorkItem?.cancel()
            self.hideWorkItem = nil
            return
        }

        let sidebarWidth: CGFloat = 76
        let hoverFrame = NSRect(
            x: self.panel.frame.maxX - sidebarWidth,
            y: self.panel.frame.minY,
            width: sidebarWidth,
            height: self.panel.frame.height).insetBy(dx: -10, dy: -10)
        if self.isRevealed, hoverFrame.contains(pointer) {
            self.hideWorkItem?.cancel()
            self.hideWorkItem = nil
        } else if self.isRevealed {
            self.scheduleConceal()
        }
    }

    private func reveal(on screen: NSScreen) {
        self.hideWorkItem?.cancel()
        self.hideWorkItem = nil
        if self.isRevealed, self.activeScreen == screen {
            return
        }
        let savedY = UserDefaults.standard.string(forKey: Self.originKey).map(NSPointFromString)?.y
        let preferredY = self.activeScreen == screen ? savedY : nil
        let shown = FloatingSidebarGeometry.shownOrigin(
            screen: screen.visibleFrame,
            panelSize: self.panel.frame.size,
            preferredY: preferredY)
        self.activeScreen = screen
        self.presentation.maximumContentHeight = self.maximumPanelHeight(for: screen)
        self.isRevealed = true
        self.presentation.isTucked = false
        self.panel.orderFrontRegardless()
        MenuSwitchFlickerProbe.debugLog("floating-sidebar reveal origin=\(shown) screen=\(screen.frame)")
        self.animatePanel(to: shown)
    }

    private func scheduleConceal() {
        guard self.hideWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.conceal(animated: true)
            }
        }
        self.hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: item)
    }

    private func conceal(animated: Bool) {
        self.hideWorkItem?.cancel()
        self.hideWorkItem = nil
        guard let screen = self.activeScreen ?? self.screen(containing: self.panel.frame.center) ?? NSScreen.main else {
            return
        }
        let shown = FloatingSidebarGeometry.shownOrigin(
            screen: screen.visibleFrame,
            panelSize: self.panel.frame.size,
            preferredY: self.panel.frame.minY)
        let hidden = FloatingSidebarGeometry.hiddenOrigin(screen: screen.frame, shownOrigin: shown)
        self.isRevealed = false
        self.presentation.isTucked = true
        self.panel.orderFrontRegardless()
        MenuSwitchFlickerProbe.debugLog("floating-sidebar conceal origin=\(hidden) animated=\(animated)")
        if animated {
            self.animatePanel(to: hidden)
        } else {
            self.setPanelOrigin(hidden)
        }
    }

    private func animatePanel(to origin: NSPoint, completion: (@MainActor () -> Void)? = nil) {
        self.isProgrammaticMove = true
        var targetFrame = self.panel.frame
        targetFrame.origin = origin
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.panel.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.isProgrammaticMove = false
                completion?()
            }
        }
    }

    private func setPanelOrigin(_ origin: NSPoint) {
        self.isProgrammaticMove = true
        self.panel.setFrameOrigin(origin)
        self.isProgrammaticMove = false
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
}

extension NSRect {
    fileprivate var center: NSPoint {
        NSPoint(x: self.midX, y: self.midY)
    }
}
