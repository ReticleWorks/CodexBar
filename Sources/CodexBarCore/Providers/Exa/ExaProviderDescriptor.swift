import Foundation

public enum ExaProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: ExaSettingsReader.serviceKeyEnvironmentKey,
        resolve: ExaSettingsReader.serviceKey)

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .exa,
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .exa,
                displayName: "Exa",
                sessionLabel: "Spend",
                weeklyLabel: "Budget",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Authoritative spend by API key.",
                toggleTitle: "Show Exa usage",
                cliName: "exa",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://dashboard.exa.ai",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .exa),
                iconResourceName: "ProviderIcon-exa",
                color: ProviderColor(hex: 0x1840ED),
                confettiPalette: [
                    ProviderColor(hex: 0x1840ED),
                    ProviderColor(hex: 0xFFFFFF),
                    ProviderColor(hex: 0x111111),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Exa reports authoritative spend by key, but not daily history." }),
            presentation: ProviderUsagePresentation(
                costPresenter: { _ in ProviderCostPresentation(menuCardStyle: .apiSpend) },
                menuCard: ProviderMenuCardPresentation(providerCostIsRequiredUsage: true)),
            fetchPlan: self.fetchPlan(),
            cli: ProviderCLIConfig(name: "exa", aliases: [], versionDetector: nil))
    }

    private static func fetchPlan() -> ProviderFetchPlan {
        ProviderFetchPlan(
            sourceModes: [.auto, .api],
            pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                [ScriptFetchStrategy(
                    id: "exa.js",
                    provider: .exa,
                    bundledPlugin: "exa",
                    secretKey: ExaSettingsReader.serviceKeyEnvironmentKey,
                    sourceLabel: "admin api",
                    resolveSecret: { environment in
                        self.credentials.resolveToken(environment: environment)?.token
                    },
                    isEnabled: { _ in true })]
            }))
    }
}
