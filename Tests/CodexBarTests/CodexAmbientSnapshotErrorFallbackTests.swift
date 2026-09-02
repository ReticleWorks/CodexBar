import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test
    func `active account error falls back to another healthy visible account's snapshot`() async {
        // Regression: build 13104 showed no Codex entry at all in the widget snapshot when the
        // active source account (e.g. an expired OAuth token) errored on every fetch, even though
        // other visible accounts sharing the provider had healthy, current data. Blanking
        // self.snapshots[.codex] to nil on any active-account failure hid every account's usage,
        // not just the erroring one.
        let suite = "CodexAmbientSnapshotErrorFallbackTests-fallback"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "erroring@example.com")
        defer { settings._test_liveSystemCodexAccount = nil }

        let store = self.makeUsageStore(settings: settings)
        let erroringAccount = CodexVisibleAccount(
            id: "live:erroring@example.com",
            email: "erroring@example.com",
            workspaceAccountID: nil,
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: true,
            isLive: true,
            canReauthenticate: true,
            canRemove: false)
        let healthyAccount = CodexVisibleAccount(
            id: "profile:/Users/test/.codex-healthy",
            email: "healthy@example.com",
            workspaceAccountID: nil,
            storedAccountID: nil,
            selectionSource: .profileHome(path: "/Users/test/.codex-healthy"),
            isActive: false,
            isLive: false,
            canReauthenticate: true,
            canRemove: true)
        let healthyUsage = self.codexSnapshot(email: "healthy@example.com", usedPercent: 46)
        store.codexAccountSnapshots = [
            CodexAccountUsageSnapshot(
                account: erroringAccount,
                snapshot: nil,
                error: "OAuth token expired",
                sourceLabel: nil,
                credits: nil),
            CodexAccountUsageSnapshot(
                account: healthyAccount,
                snapshot: healthyUsage,
                error: nil,
                sourceLabel: "oauth",
                credits: nil),
        ]

        let outcome = ProviderFetchOutcome(
            result: .failure(TestRefreshError(message: "OAuth token expired")),
            attempts: [])

        await store.applySelectedCodexVisibleAccountOutcome(
            outcome,
            account: erroringAccount,
            snapshot: nil,
            sourceLabel: nil,
            limitResetOwnerKey: nil)

        #expect(store.errors[.codex] == "OAuth token expired")
        #expect(store.snapshots[.codex]?.primary?.usedPercent == 46)
        #expect(store.snapshots[.codex]?.accountEmail(for: .codex) == "healthy@example.com")
    }
}
