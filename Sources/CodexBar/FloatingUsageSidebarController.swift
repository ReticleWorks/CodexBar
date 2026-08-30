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

enum FloatingSidebarGeometry {
    static let trailingMargin: CGFloat = 6
    static let edgeTriggerWidth: CGFloat = 2

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
        NSPoint(x: screen.maxX, y: shownOrigin.y)
    }

    static func pointerTouchesTrailingEdge(_ pointer: NSPoint, screen: NSRect) -> Bool {
        screen.contains(pointer) && pointer.x >= screen.maxX - self.edgeTriggerWidth
    }
}

@MainActor
final class FloatingUsageSidebarController {
    private nonisolated static let originKey = "LocalSpendTrackerFloatingPillOrigin"

    private let settings: SettingsStore
    private let store: UsageStore
    private let panel: NSPanel
    private let hostingController: NSHostingController<FloatingUsagePillView>
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
        openProvider: @escaping @MainActor (UsageProvider) -> Void)
    {
        self.store = store
        self.settings = settings
        self.panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 60, height: 200),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false)
        self.hostingController = NSHostingController(rootView: FloatingUsagePillView(
            store: store,
            settings: settings,
            openProvider: openProvider))

        self.panel.identifier = NSUserInterfaceItemIdentifier("floatingUsageSidebar")
        self.panel.level = .statusBar
        self.panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.panel.isMovableByWindowBackground = true
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
    }

    func start() {
        self.observeMoves()
        self.observePointer()
        self.observeVisibility()
        self.applyVisibility()
        self.runVisualProbeIfRequested()
        self.runStoreProbeIfRequested()
    }

    /// Records a short, redacted startup timeline for live acceptance checks.
    /// Ordinary launches do no work because the environment variable is absent.
    private func runStoreProbeIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_STORE_PROBE_PATH"],
              !path.isEmpty else { return }
        if let rawProvider = ProcessInfo.processInfo.environment["CODEXBAR_STORE_PROBE_REFRESH_PROVIDER"],
           let provider = UsageProvider(rawValue: rawProvider)
        {
            let delay = max(0, ProcessInfo.processInfo.environment[
                "CODEXBAR_STORE_PROBE_REFRESH_DELAY_SECONDS"].flatMap(Double.init) ?? 8)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                await self?.store.refreshProvider(provider)
            }
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let startedAt = Date()
            var rows: [[String: Any]] = []
            for delay in [0.0, 1.0, 5.0, 10.0, 20.0] {
                let elapsed = Date().timeIntervalSince(startedAt)
                if delay > elapsed {
                    try? await Task.sleep(for: .seconds(delay - elapsed))
                }
                let displayProviders = self.store.enabledFirstPartyProvidersForDisplay()
                rows.append([
                    "elapsedSeconds": Date().timeIntervalSince(startedAt),
                    "displayProviders": displayProviders.map(\.rawValue),
                    "backgroundProviders": self.store.enabledFirstPartyProvidersForBackgroundWork().map(\.rawValue),
                    "refreshingProviders": self.store.refreshingProviders.map(\.rawValue).sorted(),
                    "snapshots": displayProviders.filter {
                        self.store.presentationSnapshot(for: $0) != nil
                    }.map(\.rawValue),
                    "updatedAt": Dictionary(uniqueKeysWithValues: displayProviders.compactMap { provider in
                        self.store.presentationSnapshot(for: provider).map {
                            (provider.rawValue, $0.updatedAt.timeIntervalSince1970)
                        }
                    }),
                    "errors": Dictionary(uniqueKeysWithValues: displayProviders.compactMap { provider in
                        self.store.errors[provider.instanceID].map { (provider.rawValue, $0) }
                    }),
                ])
                guard JSONSerialization.isValidJSONObject(rows),
                      let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted])
                else { continue }
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }
    }

    /// Renders one real, populated sidebar frame without Screen Recording access.
    /// This path is inert during ordinary launches.
    private func runVisualProbeIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_SIDEBAR_PROBE_PATH"],
              !path.isEmpty else { return }
        let requestedDelay = ProcessInfo.processInfo.environment["CODEXBAR_SIDEBAR_PROBE_DELAY_SECONDS"]
            .flatMap(Double.init)
        let startDelay = max(0, requestedDelay ?? 4)
        DispatchQueue.main.asyncAfter(deadline: .now() + startDelay) { [weak self] in
            guard let self, let screen = NSScreen.main else { return }
            self.reveal(on: screen)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                let view = self.hostingController.view
                view.layoutSubtreeIfNeeded()
                guard view.bounds.width > 0,
                      view.bounds.height > 0,
                      let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                else { return }
                view.cacheDisplay(in: view.bounds, to: representation)
                guard let data = representation.representation(using: .png, properties: [:]) else { return }
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
                self.conceal(animated: false)
            }
        }
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
            size = NSSize(width: 60, height: 200)
        }
        self.panel.setContentSize(size)
        self.didSizeAndPosition = true
        let savedY = UserDefaults.standard.string(forKey: Self.originKey).map(NSPointFromString)?.y
        let screen = self.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main
        self.activeScreen = screen
        if let screen {
            let origin = FloatingSidebarGeometry.shownOrigin(
                screen: screen.visibleFrame,
                panelSize: size,
                preferredY: savedY)
            self.setPanelOrigin(origin)
        }
        self.panel.alphaValue = 1
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

        let hoverFrame = self.panel.frame.insetBy(dx: -10, dy: -10)
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
        self.isRevealed = true
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
        MenuSwitchFlickerProbe.debugLog("floating-sidebar conceal origin=\(hidden) animated=\(animated)")
        if animated {
            self.animatePanel(to: hidden) { [weak self] in
                guard let self, !self.isRevealed else { return }
                self.panel.orderOut(nil)
            }
        } else {
            self.setPanelOrigin(hidden)
            self.panel.orderOut(nil)
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

@MainActor
private struct FloatingUsagePillView: View {
    @Bindable var store: UsageStore
    @Bindable var settings: SettingsStore
    let openProvider: @MainActor (UsageProvider) -> Void
    @State private var selectedProvider: UsageProvider = .claude

    var body: some View {
        VStack(spacing: 16) {
            ForEach(self.providers, id: \.self) { provider in
                let snapshot = FloatingSidebarSnapshotResolver.snapshot(
                    for: provider,
                    providerSnapshot: self.store.presentationSnapshot(for: provider),
                    claudeAccounts: self.store.claudeSwapAccountSnapshots)
                FloatingUsagePillItem(
                    provider: provider,
                    snapshot: snapshot,
                    isSelected: self.selectedProvider == provider,
                    accentColor: self.settings.accentColor(for: provider),
                    showsUsed: ProviderUsageDisplayPolicy.showsUsed(
                        for: provider,
                        defaultShowUsed: self.settings.usageBarsShowUsed),
                    hidePersonalInfo: self.settings.hidePersonalInfo,
                    accountDisplayLabel: self.accountDisplayLabel(snapshot: snapshot),
                    openProvider: { selected in
                        self.selectedProvider = selected
                        self.openProvider(selected)
                    })
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 10)
        .frame(width: 60)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color(red: 0.035, green: 0.035, blue: 0.038).opacity(0.94)))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.white.opacity(0.09))
        }
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 4)
    }

    private var providers: [UsageProvider] {
        self.store.enabledFirstPartyProvidersForDisplay()
    }

    private func accountDisplayLabel(snapshot: UsageSnapshot?) -> String? {
        guard let email = snapshot?.identity?.accountEmail else { return nil }
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return self.settings.codexDisplayAliases[normalized]
            ?? self.settings.claudeSwapDisplayAliases[normalized]
    }
}

@MainActor
private struct FloatingUsagePillItem: View {
    let provider: UsageProvider
    let snapshot: UsageSnapshot?
    let isSelected: Bool
    let accentColor: ProviderColor
    let showsUsed: Bool
    let hidePersonalInfo: Bool
    let accountDisplayLabel: String?
    let openProvider: @MainActor (UsageProvider) -> Void

    var body: some View {
        Button {
            self.openProvider(self.provider)
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.14), lineWidth: 3)
                    if let metric = self.metric {
                        Circle()
                            .trim(from: 0, to: max(0.02, metric.ringFraction))
                            .stroke(
                                self.statusColor(usedPercent: metric.usedPercent),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    self.providerMark
                }
                .frame(width: 40, height: 40)
                .opacity(self.isSelected ? 1 : 0.6)

                if let metric = self.metric {
                    self.valueLabel(metric.compactPercent, direction: metric.directionLabel, available: true)
                } else if let costText = self.costText {
                    self.valueLabel(costText, direction: self.showsUsed ? "used" : "remaining", available: true)
                } else {
                    self.valueLabel(
                        "—",
                        direction: self.showsUsed ? "used" : "remaining",
                        available: false)
                }
            }
        }
        .buttonStyle(.plain)
        .help(self.helpText)
        .accessibilityLabel(self.helpText)
    }

    private func valueLabel(_ value: String, direction: String, available: Bool) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(available ? 0.85 : 0.35))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(direction)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(available ? 0.45 : 0.28))
                .fixedSize()
        }
    }

    @ViewBuilder
    private var providerMark: some View {
        if let image = ProviderBrandIcon.image(for: self.provider) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(self.hasValue ? self.brandColor : self.brandColor.opacity(0.45))
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "sparkle")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(self.hasValue ? self.brandColor : self.brandColor.opacity(0.45))
                .frame(width: 20, height: 20)
        }
    }

    private var metadata: ProviderMetadata {
        ProviderDescriptorRegistry.descriptor(for: self.provider).metadata
    }

    private var window: RateWindow? {
        guard let snapshot else { return nil }
        let semantic = ProviderDescriptorRegistry.descriptor(for: self.provider)
            .presentation.semanticWindows(snapshot: snapshot)
        // One compact number must represent the limiting lane, not merely the first lane.
        // This keeps a fresh 5-hour window from hiding a constrained weekly or Amp pool.
        var candidates: [RateWindow?] = [
            semantic.session,
            semantic.weekly,
            snapshot.primary,
            snapshot.secondary,
            snapshot.tertiary,
        ]
        // Claude model pools and Amp pools are real quota lanes. Codex extras are Spark lanes,
        // which this local package deliberately never surfaces.
        if self.provider != .codex {
            candidates.append(contentsOf: snapshot.extraRateWindows?.map(\.window) ?? [])
        }
        return FloatingUsageMetric.mostConstrainedWindow(candidates)
    }

    private var metric: FloatingUsageMetric? {
        FloatingUsageMetric.resolve(window: self.window, showsUsed: self.showsUsed)
    }

    private var costText: String? {
        guard let cost = self.snapshot?.providerCost else { return nil }
        let amount: Double
        if self.showsUsed {
            amount = cost.used
        } else if let balance = cost.balance {
            amount = balance
        } else if cost.limit > 0 {
            amount = max(0, cost.limit - cost.used)
        } else {
            return nil
        }
        guard amount.isFinite else { return nil }
        let prefix = cost.currencyCode.uppercased() == "USD" ? "$" : "\(cost.currencyCode.uppercased()) "
        return prefix + String(format: amount >= 100 ? "%.0f" : "%.2f", amount)
    }

    private var hasValue: Bool {
        self.metric != nil || self.costText != nil
    }

    private var brandColor: Color {
        Color(red: self.accentColor.red, green: self.accentColor.green, blue: self.accentColor.blue)
    }

    private var accountLabel: String? {
        guard !self.hidePersonalInfo else { return nil }
        return self.accountDisplayLabel ?? self.snapshot?.identity?.accountEmail
    }

    private var helpText: String {
        let account = self.accountLabel.map { " · \($0)" } ?? ""
        guard let metric else {
            if let costText {
                return "\(self.metadata.displayName)\(account) · \(costText) "
                    + (self.showsUsed ? "used" : "remaining")
            }
            return "\(self.metadata.displayName)\(account) · usage unavailable"
        }
        return "\(self.metadata.displayName)\(account) · \(metric.compactPercent) \(metric.directionLabel)"
    }

    private func statusColor(usedPercent: Double) -> Color {
        let fraction = usedPercent / 100
        if self.provider == .claude {
            if fraction >= 0.95 { return Color(red: 0.98, green: 0.35, blue: 0.20) }
            if fraction >= 0.80 { return Color(red: 0.98, green: 0.80, blue: 0.20) }
            return self.brandColor
        }
        switch fraction {
        case ..<0.50:
            return Color(red: 0.30, green: 0.85, blue: 0.45)
        case ..<0.80:
            return Color(red: 0.98, green: 0.80, blue: 0.20)
        default:
            return Color(red: 0.98, green: 0.35, blue: 0.20)
        }
    }
}
