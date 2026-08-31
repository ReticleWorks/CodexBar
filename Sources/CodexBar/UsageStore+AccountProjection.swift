import CodexBarCore
import Foundation

/// Builds the one read-only account surface consumed by menus and the sidebar.
/// This method only joins already-published identities and usage. It never
/// fetches, persists, reads credentials, or changes an active account.
extension UsageStore {
    func accountProjection(for provider: UsageProvider) -> AccountProjection {
        switch provider {
        case .claude:
            self.claudeAccountProjection()
        case .codex:
            self.codexAccountProjection()
        default:
            .empty(for: provider)
        }
    }

    private func claudeAccountProjection() -> AccountProjection {
        let subscriptions = self.claudeSwapAccountSnapshots.map { account in
            let switchError = self.claudeSwapTransientState.lastErrorAccountID == account.id
                ? self.claudeSwapTransientState.lastError
                : nil
            return ProviderAccountUsageSnapshot(
                id: account.id,
                provider: .claude,
                displayLabel: account.displayLabel,
                accountEmail: account.accountEmail,
                isActive: account.isActive,
                canActivate: account.canActivate,
                snapshot: account.snapshot,
                error: ClaudeSwapAccountProjection.displayError(
                    accountError: account.error,
                    adapterError: self.claudeSwapLastError,
                    switchError: switchError),
                sourceLabel: account.sourceLabel ?? ClaudeSwapAccountProjection.sourceLabel)
        }

        let configuredAPIs = self.settings.tokenAccounts(for: .claude)
        let cachedAPIs = self.accountSnapshots[UsageProvider.claude.instanceID] ?? []
        let selectedAPIID = self.settings.effectiveSelectedTokenAccount(for: .claude)?.id
        let apiSpend = configuredAPIs.map { account in
            let cacheKey = self.tokenAccountSnapshotCacheKey(provider: .claude, account: account)
            let cached = cachedAPIs.first {
                $0.account.id == account.id && $0.cacheKey == cacheKey
            }
            return ProviderAccountUsageSnapshot(
                id: ProviderAccountIdentity(
                    source: AccountProjectionSource.claudeAdminAPI,
                    opaqueID: account.id.uuidString),
                provider: .claude,
                displayLabel: account.displayName,
                isActive: account.id == selectedAPIID,
                canActivate: false,
                snapshot: cached?.snapshot,
                error: cached?.error,
                sourceLabel: cached?.sourceLabel ?? AccountProjectionSource.claudeAdminAPILabel)
        }

        let updatedAt = (subscriptions + apiSpend).compactMap { $0.snapshot?.updatedAt }.max()
        return AccountProjection(
            provider: .claude,
            subscriptions: subscriptions,
            apiSpend: apiSpend,
            isRefreshing: self.refreshingProviders.contains(UsageProvider.claude.instanceID)
                || self.claudeSwapRefreshTask != nil,
            lastUpdatedAt: [updatedAt, self.claudeSwapLastRefreshAt].compactMap(\.self).max(),
            lastError: self.claudeSwapLastError)
    }

    private func codexAccountProjection() -> AccountProjection {
        guard let authority = self.settings.codexVisibleAccountProjectionForMenuDisplay else {
            return AccountProjection(
                provider: .codex,
                isRefreshing: self.refreshingProviders.contains(UsageProvider.codex.instanceID),
                lastError: self.errors[UsageProvider.codex.instanceID])
        }

        let subscriptions = authority.visibleAccounts.map { account in
            let retained = self.codexAccountSnapshots.first {
                $0.id == account.id
                    && Self.codexPriorSnapshotAccountMatches($0.account, account: account)
            }
            let health = CodexAccountHealth.status(for: account, error: retained?.error)
            return ProviderAccountUsageSnapshot(
                id: ProviderAccountIdentity(source: AccountProjectionSource.codex, opaqueID: account.id),
                provider: .codex,
                displayLabel: self.settings.codexDisplayAliases[account.email.lowercased()]
                    ?? account.menuDisplayName,
                accountEmail: account.email,
                isActive: account.id == authority.activeVisibleAccountID || account.isActive,
                canActivate: account.id != authority.activeVisibleAccountID && !account.isActive,
                snapshot: codexPresentationSnapshot(
                    snapshot: retained?.snapshot,
                    credits: retained?.credits),
                error: health.label,
                sourceLabel: retained?.sourceLabel)
        }
        return AccountProjection(
            provider: .codex,
            subscriptions: subscriptions,
            isRefreshing: self.refreshingProviders.contains(UsageProvider.codex.instanceID),
            lastError: self.errors[UsageProvider.codex.instanceID])
    }
}

enum AccountProjectionSource {
    static let claudeAdminAPI = "claude-admin-api"
    static let claudeAdminAPILabel = "admin-api"
    static let codex = "codex-account"
}

func codexPresentationSnapshot(snapshot: UsageSnapshot?, credits: CreditsSnapshot?) -> UsageSnapshot? {
    guard let limit = credits?.codexCreditLimit else { return snapshot }
    let monthly = RateWindow(
        usedPercent: limit.usedPercent,
        windowMinutes: nil,
        resetsAt: limit.resetsAt,
        resetDescription: nil)
    guard let snapshot else {
        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: monthly,
            updatedAt: limit.updatedAt)
    }
    if snapshot.tertiary == nil {
        return snapshot.with(tertiary: monthly)
    }
    let extras = (snapshot.extraRateWindows ?? []) + [
        NamedRateWindow(
            id: "codex-monthly-credit",
            title: limit.title,
            window: monthly),
    ]
    return snapshot.with(extraRateWindows: extras)
}
