import Foundation

public enum TinkerProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: TinkerSettingsReader.apiKeyEnvironmentKey,
        resolve: TinkerSettingsReader.apiKey,
        tokenAccountSupport: TokenAccountSupport(
            title: "API keys",
            subtitle: "Store multiple Thinking Machines Tinker API keys.",
            placeholder: "tml-...",
            injection: .environment(key: TinkerSettingsReader.apiKeyEnvironmentKey),
            requiresManualCookieSource: false,
            cookieName: nil))

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .tinker,
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .tinker,
                displayName: "Thinking Machines",
                shortDisplayName: "Tinker",
                sessionLabel: "14-day spend",
                weeklyLabel: "Tokens",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Tinker billing events and list-price estimate.",
                toggleTitle: "Show Thinking Machines usage",
                cliName: "tinker",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://tinker.thinkingmachines.ai",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .tinker),
                iconResourceName: "ProviderIcon-tinker",
                color: ProviderColor(hex: 0x111111),
                confettiPalette: [
                    ProviderColor(hex: 0x000000),
                    ProviderColor(hex: 0xF3F2F2),
                    ProviderColor(hex: 0xE6E6E6),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: {
                    "Thinking Machines usage comes from billing events; dollar totals are list-price estimates."
                }),
            presentation: ProviderUsagePresentation(
                costPresenter: { _ in ProviderCostPresentation(menuCardStyle: .apiSpend) },
                menuCard: ProviderMenuCardPresentation(providerCostIsRequiredUsage: true)),
            fetchPlan: .apiToken(
                strategyID: "tinker.api",
                resolveToken: { ProviderTokenResolver.token(for: .tinker, environment: $0) },
                missingCredentialsError: { TinkerUsageError.missingCredentials },
                loadUsage: { apiKey, _ in
                    try await TinkerUsageFetcher.fetchUsage(apiKey: apiKey)
                }),
            cli: ProviderCLIConfig(name: "tinker", aliases: ["tml"], versionDetector: nil))
    }
}
