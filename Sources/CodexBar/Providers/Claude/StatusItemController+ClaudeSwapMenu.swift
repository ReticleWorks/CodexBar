import AppKit
import CodexBarCore

extension StatusItemController {
    func addClaudeSwapMenuCards(
        to menu: NSMenu,
        captureMenu: NSMenu,
        context: MenuCardContext)
    {
        let accounts = self.store.claudeSwapAccountSnapshots
        if self.settings.multiAccountMenuLayout == .segmented, accounts.count > 1 {
            menu.addItem(self.makeClaudeSwapAccountSwitcherItem(
                accounts: accounts,
                menu: captureMenu,
                width: context.menuWidth))
            menu.addItem(.separator())
            let selected = accounts.first(where: \.isActive) ?? accounts.first
            self.addStackedClaudeSwapMenuCards(
                accounts: selected.map { [$0] } ?? [],
                to: menu,
                captureMenu: captureMenu,
                context: context)
            self.addClaudeAPIMenuCardsIfAvailable(to: menu, context: context)
            return
        }
        let plan = self.compactAccountPlan(for: .claude, accounts: accounts)
        guard plan.usesCompactLayout else {
            self.addStackedClaudeSwapMenuCards(accounts: accounts, to: menu, captureMenu: captureMenu, context: context)
            self.addClaudeAPIMenuCardsIfAvailable(to: menu, context: context)
            return
        }
        self.addCompactAccountMenuRows(
            CompactAccountMenuRendering(
                plan: plan,
                accounts: accounts,
                idPrefix: "claudeSwap",
                cardModel: { [weak self] account in
                    self?.claudeSwapCardModel(for: account)
                },
                planAction: { [weak self] account in
                    self?.claudeSwapAccountSwitchAction(account, menu: captureMenu)
                }),
            to: menu,
            captureMenu: captureMenu,
            context: context)
        self.addClaudeAPIMenuCardsIfAvailable(to: menu, context: context)
    }

    private func makeClaudeSwapAccountSwitcherItem(
        accounts: [ProviderAccountUsageSnapshot],
        menu: NSMenu,
        width: CGFloat) -> NSMenuItem
    {
        let view = ClaudeSwapAccountSwitcherView(
            accounts: accounts,
            selectedAccountID: accounts.first(where: \.isActive)?.id,
            width: width,
            onSelect: { [weak self, weak menu] account in
                guard let self, let menu, !account.isActive,
                      let action = self.claudeSwapAccountSwitchAction(account, menu: menu)
                else { return }
                action()
            })
        let item = NSMenuItem()
        item.title = ""
        item.view = view
        item.isEnabled = false
        return item
    }

    private func addClaudeAPIMenuCardsIfAvailable(to menu: NSMenu, context: MenuCardContext) {
        let accounts = self.settings.tokenAccounts(for: .claude)
        let snapshots = self.store.validTokenAccountSnapshots(provider: .claude, accounts: accounts)
        let cards = snapshots.compactMap { snapshot -> (UUID, UsageMenuCardView.Model)? in
            guard let model = self.tokenAccountMenuCardModel(for: .claude, accountSnapshot: snapshot) else {
                return nil
            }
            return (snapshot.account.id, model)
        }
        guard !cards.isEmpty else { return }

        let header = NSMenuItem(title: L("API spend"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.representedObject = "claudeAPIHeader"
        menu.addItem(.separator())
        menu.addItem(header)
        for (index, card) in cards.enumerated() {
            menu.addItem(self.makeMenuCardItem(
                UsageMenuCardView(model: card.1, width: context.menuWidth),
                id: "claudeAPI-\(card.0.uuidString)",
                width: context.menuWidth,
                heightCacheScope: "claude-api-\(card.0.uuidString)",
                heightCacheFingerprint: card.1.heightFingerprint(section: "api"),
                containsInteractiveControls: true))
            if index < cards.count - 1 {
                menu.addItem(.separator())
            }
        }
    }

    private func addStackedClaudeSwapMenuCards(
        accounts: [ProviderAccountUsageSnapshot],
        to menu: NSMenu,
        captureMenu: NSMenu,
        context: MenuCardContext)
    {
        let cardRows = accounts.compactMap { account ->
            (account: ProviderAccountUsageSnapshot, model: UsageMenuCardView.Model)? in
            guard let model = self.claudeSwapCardModel(for: account) else { return nil }
            return (account, model)
        }
        self.addStackedMenuCards(
            cardRows.map(\.model),
            to: menu,
            context: context,
            planAction: { [weak self] index in
                guard cardRows.indices.contains(index) else { return nil }
                return self?.claudeSwapAccountSwitchAction(cardRows[index].account, menu: captureMenu)
            })
    }

    private func claudeSwapCardModel(for account: ProviderAccountUsageSnapshot) -> UsageMenuCardView.Model? {
        self.menuCardModel(
            for: .claude,
            snapshotOverride: account.snapshot,
            errorOverride: ClaudeSwapAccountProjection.displayError(
                accountError: account.error,
                adapterError: self.store.claudeSwapLastError,
                switchError: self.store.claudeSwapTransientState.lastErrorAccountID == account.id
                    ? self.store.claudeSwapTransientState.lastError
                    : nil),
            forceOverrideCard: account.snapshot == nil,
            accountOverride: AccountInfo(
                email: account.displayLabel,
                plan: nil),
            planOverride: self.claudeSwapAccountActionLabel(account),
            sourceLabelOverride: ClaudeSwapAccountProjection.sourceLabel)
    }

    private func claudeSwapAccountActionLabel(_ account: ProviderAccountUsageSnapshot) -> String? {
        if account.isActive {
            return L("Active")
        }
        if self.store.claudeSwapTransientState.switchingAccountID == account.id {
            return L("Loading…")
        }
        guard self.store.claudeSwapTransientState.task == nil, account.canActivate else { return nil }
        return L("Switch Account...")
    }

    private func claudeSwapAccountSwitchAction(
        _ account: ProviderAccountUsageSnapshot,
        menu: NSMenu)
        -> (() -> Void)?
    {
        guard self.store.claudeSwapTransientState.task == nil, account.canActivate else { return nil }
        let accountID = account.id
        return { [weak self, weak menu] in
            guard let self else { return }
            self.advanceMenuInteraction(for: menu)
            self.store.switchClaudeSwapAccount(accountID)
        }
    }
}
