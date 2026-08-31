import AppKit
import CodexBarCore

extension StatusItemController {
    func addClaudeSwapMenuCards(
        to menu: NSMenu,
        captureMenu: NSMenu,
        context: MenuCardContext)
    {
        let projection = self.store.accountProjection(for: .claude)
        let accounts = projection.subscriptions
        if self.settings.multiAccountMenuLayout == .segmented, accounts.count > 1 {
            let selected = self.claudeSwapDisplayAccount(in: accounts)
            menu.addItem(self.makeClaudeSwapAccountSwitcherItem(
                options: accounts,
                selectedAccountID: selected?.id,
                menu: captureMenu,
                width: context.menuWidth))
            menu.addItem(.separator())
            self.addStackedClaudeSwapMenuCards(
                accounts: selected.map { [$0] } ?? [],
                to: menu,
                captureMenu: captureMenu,
                context: context)
            self.addClaudeAPIMenuCardsIfAvailable(
                to: menu,
                context: context,
                projection: projection)
            return
        }
        let plan = self.compactAccountPlan(for: .claude, accounts: accounts)
        guard plan.usesCompactLayout else {
            self.addStackedClaudeSwapMenuCards(accounts: accounts, to: menu, captureMenu: captureMenu, context: context)
            self.addClaudeAPIMenuCardsIfAvailable(
                to: menu,
                context: context,
                projection: projection)
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
        self.addClaudeAPIMenuCardsIfAvailable(
            to: menu,
            context: context,
            projection: projection)
    }

    private func makeClaudeSwapAccountSwitcherItem(
        options: [ProviderAccountUsageSnapshot],
        selectedAccountID: ProviderAccountIdentity?,
        menu: NSMenu,
        width: CGFloat) -> NSMenuItem
    {
        let view = ClaudeSwapAccountSwitcherView(
            options: options,
            selectedAccountID: selectedAccountID,
            width: width,
            accentColor: Self.accountSwitcherAccentColor(for: .claude),
            onSelect: { [weak self, weak menu] option in
                guard let self, let menu, self.selectedClaudeSwapDisplayAccountID != option.id else { return }
                self.advanceMenuInteraction(for: menu)
                self.selectedClaudeSwapDisplayAccountID = option.id
                self.invalidateMenus()
                self.deferSwitcherMenuRebuildIfStillVisible(menu, provider: .claude)
            })
        let item = NSMenuItem()
        item.title = ""
        item.view = view
        item.isEnabled = false
        return item
    }

    private func claudeSwapDisplayAccount(
        in accounts: [ProviderAccountUsageSnapshot]) -> ProviderAccountUsageSnapshot?
    {
        if let selectedClaudeSwapDisplayAccountID,
           let selected = accounts.first(where: { $0.id == selectedClaudeSwapDisplayAccountID })
        {
            return selected
        }
        return accounts.first(where: \.isActive) ?? accounts.first
    }

    private func addClaudeAPIMenuCardsIfAvailable(
        to menu: NSMenu,
        context: MenuCardContext,
        projection: AccountProjection)
    {
        let accountsByID = Dictionary(
            uniqueKeysWithValues: self.settings.tokenAccounts(for: .claude).map { ($0.id, $0) })
        let cards = projection.apiSpend.compactMap { row -> (ProviderAccountUsageSnapshot, UsageMenuCardView.Model)? in
            guard let accountID = UUID(uuidString: row.id.opaqueID),
                  let account = accountsByID[accountID]
            else { return nil }
            let accountSnapshot = TokenAccountUsageSnapshot(
                account: account,
                snapshot: row.snapshot,
                error: row.error,
                sourceLabel: row.sourceLabel,
                cacheKey: self.store.tokenAccountSnapshotCacheKey(provider: .claude, account: account))
            guard let model = self.tokenAccountMenuCardModel(for: .claude, accountSnapshot: accountSnapshot) else {
                return nil
            }
            return (row, model)
        }
        guard !cards.isEmpty else { return }

        let header = NSMenuItem(title: L("API spend"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.representedObject = "claudeAPIHeader"
        menu.addItem(.separator())
        menu.addItem(header)
        for (row, model) in cards {
            let detailsMenu = NSMenu()
            detailsMenu.autoenablesItems = false
            detailsMenu.addItem(self.makeMenuCardItem(
                UsageMenuCardView(model: model, width: context.menuWidth),
                id: "claudeAPI-\(row.id.opaqueID)",
                width: context.menuWidth,
                heightCacheScope: "claude-api-\(row.id.opaqueID)",
                heightCacheFingerprint: model.heightFingerprint(section: "api"),
                containsInteractiveControls: true))
            let spend = model.providerCost?.spendLine
                ?? row.error
                ?? (projection.isRefreshing ? L("Refreshing") : L("Not fetched yet"))
            let account = row.displayLabel.isEmpty ? L("Claude API") : row.displayLabel
            let item = NSMenuItem(
                title: "\(account) · \(spend)",
                action: nil,
                keyEquivalent: "")
            item.representedObject = "claudeAPISummary-\(row.id.opaqueID)"
            item.submenu = detailsMenu
            menu.addItem(item)
        }
    }

    private func addStackedClaudeSwapMenuCards(
        accounts: [ProviderAccountUsageSnapshot],
        to menu: NSMenu,
        captureMenu: NSMenu,
        context: MenuCardContext)
    {
        let cardRows = accounts.compactMap { option ->
            (option: ProviderAccountUsageSnapshot, model: UsageMenuCardView.Model)? in
            guard let model = self.claudeSwapCardModel(for: option) else { return nil }
            return (option, model)
        }
        self.addStackedMenuCards(
            cardRows.map(\.model),
            to: menu,
            context: context,
            planAction: { [weak self] index in
                guard cardRows.indices.contains(index) else { return nil }
                return self?.claudeSwapAccountSwitchAction(cardRows[index].option, menu: captureMenu)
            })
    }

    private func claudeSwapCardModel(for option: ProviderAccountUsageSnapshot) -> UsageMenuCardView.Model? {
        self.menuCardModel(
            for: .claude,
            snapshotOverride: option.snapshot,
            errorOverride: option.error,
            forceOverrideCard: option.snapshot == nil || option.error != nil,
            accountOverride: AccountInfo(
                email: option.displayLabel,
                plan: nil),
            planOverride: self.claudeSwapAccountActionLabel(option),
            sourceLabelOverride: option.sourceLabel)
    }

    private func claudeSwapAccountActionLabel(_ option: ProviderAccountUsageSnapshot) -> String? {
        if option.isActive {
            return L("Active")
        }
        if self.store.claudeSwapTransientState.switchingAccountID == option.id {
            return L("Loading…")
        }
        guard self.store.claudeSwapTransientState.task == nil, option.canActivate else { return nil }
        return L("Switch Account...")
    }

    private func claudeSwapAccountSwitchAction(
        _ option: ProviderAccountUsageSnapshot,
        menu: NSMenu)
        -> (() -> Void)?
    {
        guard self.store.claudeSwapTransientState.task == nil, option.canActivate else { return nil }
        let accountID = option.id
        return { [weak self, weak menu] in
            guard let self else { return }
            self.advanceMenuInteraction(for: menu)
            self.store.switchClaudeSwapAccount(accountID)
        }
    }
}
