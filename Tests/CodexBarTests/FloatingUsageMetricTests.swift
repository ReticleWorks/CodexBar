import CodexBarCore
import Testing
@testable import CodexBar

struct FloatingUsageMetricTests {
    @Test
    func `sidebar geometry starts outside the screen and reveals inside it`() {
        let screen = NSRect(x: 900, y: 1169, width: 2560, height: 1440)
        let size = NSSize(width: 60, height: 432)
        let shown = FloatingSidebarGeometry.shownOrigin(screen: screen, panelSize: size, preferredY: nil)
        let hidden = FloatingSidebarGeometry.hiddenOrigin(screen: screen, shownOrigin: shown)

        #expect(shown.x == 3394)
        #expect(shown.y == 1673)
        #expect(hidden.x == screen.maxX)
        #expect(hidden.y == shown.y)
        #expect(FloatingSidebarGeometry.pointerTouchesTrailingEdge(
            NSPoint(x: screen.maxX - 1, y: screen.midY),
            screen: screen))
        #expect(!FloatingSidebarGeometry.pointerTouchesTrailingEdge(
            NSPoint(x: screen.maxX - 3, y: screen.midY),
            screen: screen))
    }

    @Test
    func `provider directions match vendor semantics`() {
        #expect(ProviderUsageDisplayPolicy.showsUsed(for: .claude, defaultShowUsed: false))
        #expect(!ProviderUsageDisplayPolicy.showsUsed(for: .codex, defaultShowUsed: true))
        #expect(!ProviderUsageDisplayPolicy.showsUsed(for: .amp, defaultShowUsed: true))
        #expect(!ProviderUsageDisplayPolicy.showsUsed(for: .openrouter, defaultShowUsed: true))
        #expect(!ProviderUsageDisplayPolicy.showsUsed(for: .tavily, defaultShowUsed: true))
        #expect(ProviderUsageDisplayPolicy.showsUsed(for: .fireworks, defaultShowUsed: false))
        #expect(ProviderUsageDisplayPolicy.showsUsed(for: .googleai, defaultShowUsed: false))
    }

    @Test
    func `used metric preserves vendor reported usage`() throws {
        let window = RateWindow(usedPercent: 82, windowMinutes: 300, resetsAt: nil)
        let metric = try #require(FloatingUsageMetric.resolve(window: window, showsUsed: true))

        #expect(metric.usedPercent == 82)
        #expect(metric.displayedPercent == 82)
        #expect(metric.compactPercent == "82%")
        #expect(metric.directionLabel == "used")
        #expect(metric.ringFraction == 0.82)
    }

    @Test
    func `remaining metric inverts without changing risk`() throws {
        let window = RateWindow(usedPercent: 82, windowMinutes: 300, resetsAt: nil)
        let metric = try #require(FloatingUsageMetric.resolve(window: window, showsUsed: false))

        #expect(metric.usedPercent == 82)
        #expect(metric.displayedPercent == 18)
        #expect(metric.compactPercent == "18%")
        #expect(metric.directionLabel == "remaining")
        #expect(metric.ringFraction == 0.18)
    }

    @Test
    func `sidebar uses the most constrained quota lane`() throws {
        let freshSession = RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil)
        let constrainedWeekly = RateWindow(usedPercent: 41, windowMinutes: 10080, resetsAt: nil)
        let selected = try #require(FloatingUsageMetric.mostConstrainedWindow([
            freshSession,
            constrainedWeekly,
        ]))

        #expect(selected.usedPercent == 41)
        #expect(FloatingUsageMetric.resolve(window: selected, showsUsed: false)?.compactPercent == "59%")
    }

    @Test
    func `claude scoped model lane can drive sidebar warning`() throws {
        let session = RateWindow(usedPercent: 3, windowMinutes: 300, resetsAt: nil)
        let weekly = RateWindow(usedPercent: 65, windowMinutes: 10080, resetsAt: nil)
        let fable = RateWindow(usedPercent: 87, windowMinutes: 10080, resetsAt: nil)
        let selected = try #require(FloatingUsageMetric.mostConstrainedWindow([session, weekly, fable]))

        #expect(selected.usedPercent == 87)
        #expect(FloatingUsageMetric.resolve(window: selected, showsUsed: true)?.compactPercent == "87%")
    }

    @Test
    func `claude sidebar prefers active subscription over admin api spend`() throws {
        let adminAPI = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 588,
                limit: 0,
                currencyCode: "USD",
                updatedAt: Date()),
            updatedAt: Date())
        let subscription = UsageSnapshot(
            primary: RateWindow(usedPercent: 27, windowMinutes: 300, resetsAt: nil),
            secondary: RateWindow(usedPercent: 6, windowMinutes: 10080, resetsAt: nil),
            updatedAt: Date())
        let account = ProviderAccountUsageSnapshot(
            id: ProviderAccountIdentity(source: "claude-swap", opaqueID: "3"),
            provider: .claude,
            displayLabel: "rherr@american",
            isActive: true,
            canActivate: false,
            snapshot: subscription,
            error: nil,
            sourceLabel: "claude-swap")

        let resolved = try #require(FloatingSidebarSnapshotResolver.snapshot(
            for: .claude,
            providerSnapshot: adminAPI,
            claudeAccounts: [account]))

        #expect(resolved.primary?.usedPercent == 27)
        #expect(resolved.providerCost == nil)
    }

    @Test
    func `over limit remaining metric does not go negative`() throws {
        let window = RateWindow(usedPercent: 125, windowMinutes: nil, resetsAt: nil)
        let metric = try #require(FloatingUsageMetric.resolve(window: window, showsUsed: false))

        #expect(metric.displayedPercent == 0)
        #expect(metric.compactPercent == "0%")
        #expect(metric.ringFraction == 0)
    }
}
