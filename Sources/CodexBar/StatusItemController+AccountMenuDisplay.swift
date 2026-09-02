import AppKit
import CodexBarCore

enum ClaudeSwapMenuPrecedence {
    static func prefersClaudeSwap(
        provider: UsageProvider,
        accountCount: Int,
        showSingleAccount: Bool) -> Bool
    {
        // Provider-specific by design: claude-swap subprocess discovery owns Claude account presentation.
        provider == .claude && ClaudeSwapAccountProjection.shouldPresentAccounts(
            accountCount: accountCount,
            showSingleAccount: showSingleAccount)
    }
}

extension StatusItemController {
    private static let defaultCodexAccountMenuProjectionRevalidationEnabled = !SettingsStore.isRunningTests

    #if DEBUG
    private static var codexAccountMenuProjectionRevalidationEnabledForTesting =
        defaultCodexAccountMenuProjectionRevalidationEnabled

    static func setCodexAccountMenuProjectionRevalidationEnabledForTesting(_ enabled: Bool) {
        self.codexAccountMenuProjectionRevalidationEnabledForTesting = enabled
    }

    static func resetCodexAccountMenuProjectionRevalidationEnabledForTesting() {
        self.codexAccountMenuProjectionRevalidationEnabledForTesting =
            self.defaultCodexAccountMenuProjectionRevalidationEnabled
    }
    #endif

    private static var codexAccountMenuProjectionRevalidationEnabled: Bool {
        #if DEBUG
        self.codexAccountMenuProjectionRevalidationEnabledForTesting
        #else
        self.defaultCodexAccountMenuProjectionRevalidationEnabled
        #endif
    }

    func tokenAccountMenuDisplay(for provider: UsageProvider) -> TokenAccountMenuDisplay? {
        guard TokenAccountSupportCatalog.support(for: provider) != nil else { return nil }
        // Retained Cursor manual accounts are dormant while Automatic browser discovery owns the live snapshot.
        guard self.settings.effectiveSelectedTokenAccount(for: provider) != nil else { return nil }
        // Eligible claude-swap rows are the selected Claude account source, so do not mix them
        // with token-account cards or the segmented token-account switcher.
        if ClaudeSwapMenuPrecedence.prefersClaudeSwap(
            provider: provider,
            accountCount: self.store.accountProjection(for: .claude).subscriptions.count,
            showSingleAccount: self.settings.claudeSwapShowSingleAccount)
        {
            return nil
        }
        let accounts = self.settings.tokenAccounts(for: provider)
        guard accounts.count > 1 else { return nil }
        let activeIndex = self.settings.tokenAccountsData(for: provider)?.clampedActiveIndex() ?? 0
        let showAll = self.settings.multiAccountMenuLayout == .stacked
        let displayAccounts = showAll
            ? self.store.limitedTokenAccounts(accounts, selected: self.settings.selectedTokenAccount(for: provider))
            : accounts
        let snapshots = showAll
            ? self.tokenAccountSnapshots(for: provider, matching: displayAccounts)
            : []
        return TokenAccountMenuDisplay(
            provider: provider,
            accounts: displayAccounts,
            snapshots: snapshots,
            activeIndex: activeIndex,
            layout: showAll ? .stacked : .segmented)
    }

    private func tokenAccountSnapshots(
        for provider: UsageProvider,
        matching accounts: [ProviderTokenAccount]) -> [TokenAccountUsageSnapshot]
    {
        var snapshotsByID: [UUID: TokenAccountUsageSnapshot] = [:]
        for snapshot in self.store.validTokenAccountSnapshots(provider: provider, accounts: accounts) {
            snapshotsByID[snapshot.account.id] = snapshot
        }
        return accounts.compactMap { snapshotsByID[$0.id] }
    }

    func tokenAccountMenuCardModel(
        for provider: UsageProvider,
        accountSnapshot: TokenAccountUsageSnapshot) -> UsageMenuCardView.Model?
    {
        let label = accountSnapshot.account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return self.menuCardModel(
            for: provider,
            snapshotOverride: accountSnapshot.snapshot,
            errorOverride: accountSnapshot.error,
            forceOverrideCard: true,
            accountOverride: AccountInfo(email: label.isEmpty ? nil : label, plan: nil),
            historySelectionOverride: self.store.planUtilizationHistorySelection(
                for: provider,
                account: accountSnapshot.account))
    }

    func codexAccountMenuDisplay(for provider: UsageProvider) -> CodexAccountMenuDisplay? {
        // Provider-specific by design: managed Codex profiles use reconciled visible-account projection state.
        guard provider == .codex else { return nil }
        guard let projection = self.settings.codexVisibleAccountProjectionForMenuDisplay else { return nil }
        guard projection.visibleAccounts.count > 1 else { return nil }
        let showAll = self.settings.multiAccountMenuLayout == .stacked
        let accounts = showAll
            ? self.store.limitedCodexVisibleAccounts(
                projection.visibleAccounts,
                snapshots: self.store.codexAccountSnapshots,
                activeVisibleAccountID: projection.activeVisibleAccountID)
            : projection.visibleAccounts
        let snapshots = showAll ? self.codexAccountSnapshots(matching: accounts) : []
        return CodexAccountMenuDisplay(
            accounts: accounts,
            snapshots: snapshots,
            activeVisibleAccountID: projection.activeVisibleAccountID,
            layout: showAll ? .stacked : .segmented)
    }

    func scheduleCodexAccountMenuProjectionRevalidationIfNeeded(for providers: [UsageProvider]) {
        let log = CodexBarLog.logger(LogCategories.providers)
        guard Self.codexAccountMenuProjectionRevalidationEnabled else {
            log.warning("codex menu revalidation skipped: disabled")
            return
        }
        guard providers.contains(.codex) else { return }
        guard self.settings.codexAccountMenuProjectionNeedsRevalidation else {
            log.warning("codex menu revalidation skipped: not needed")
            return
        }
        guard self.codexAccountMenuProjectionRevalidationTask == nil else {
            log.warning("codex menu revalidation skipped: already in flight")
            return
        }
        log.warning("codex menu revalidation scheduled")

        self.codexAccountMenuProjectionRevalidationTask = Task { @MainActor [weak self] in
            guard let settings = self?.settings else { return }
            let result = await settings.revalidateCodexAccountMenuProjection()
            log.warning("codex menu revalidation result=\(String(describing: result))")
            guard let self else { return }
            guard !Task.isCancelled else {
                self.codexAccountMenuProjectionRevalidationTask = nil
                return
            }
            self.codexAccountMenuProjectionRevalidationTask = nil

            switch result {
            case .updated:
                self.invalidateMenus(
                    refreshOpenMenus: !self.openMenus.isEmpty,
                    deferOpenParentMenuRebuild: true,
                    allowStaleContentDuringDataRefresh: true)
            case .discarded:
                // The active source (or reconciliation generation) changed while this load was in
                // flight, e.g. an account switch landed during a menu-open revalidation. The
                // "already in flight" guard above dropped that switch's own request, so the current
                // source's projection is still stale — retry now that the task handle is clear.
                self.scheduleCodexAccountMenuProjectionRevalidationIfNeeded(for: [.codex])
            case .skipped, .unchanged:
                break
            }
        }
    }

    private func codexAccountSnapshots(matching accounts: [CodexVisibleAccount]) -> [CodexAccountUsageSnapshot] {
        accounts.compactMap { account in
            self.store.codexAccountSnapshots.first { snapshot in
                snapshot.id == account.id &&
                    UsageStore.codexPriorSnapshotAccountMatches(snapshot.account, account: account)
            }
        }
    }

    /// Menu readiness is a read-only join of the cached authoritative account projection and usage rows. It must
    /// not re-read auth files or start a provider fetch while AppKit is opening the menu.
    func codexVisibleAccountUsageNeedsRefreshOnMenuOpen() -> Bool {
        guard let projection = self.settings.codexVisibleAccountProjectionForMenuDisplay,
              projection.visibleAccounts.count > 1
        else { return false }

        return projection.visibleAccounts.contains { account in
            guard let snapshot = self.store.codexAccountSnapshots.first(where: {
                $0.id == account.id &&
                    UsageStore.codexPriorSnapshotAccountMatches($0.account, account: account)
            }) else {
                return true
            }
            return snapshot.snapshot == nil
        }
    }

    func stableCodexAccountMenuDisplay(
        _ display: CodexAccountMenuDisplay?,
        menu: NSMenu,
        provider: UsageProvider) -> CodexAccountMenuDisplay?
    {
        guard provider == .codex else { return display }
        guard display == nil else { return display }
        guard self.openMenus[ObjectIdentifier(menu)] != nil else { return display }
        guard menu.items.contains(where: { $0.view is CodexAccountSwitcherView }) else { return display }
        guard let previous = self.lastCodexAccountMenuDisplay, previous.showSwitcher else { return display }
        return previous
    }
}
