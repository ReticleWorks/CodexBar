import Foundation

public enum TavilyProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: TavilySettingsReader.apiKeyEnvironmentKey,
        resolve: TavilySettingsReader.apiKey)

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .tavily,
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .tavily,
                displayName: "Tavily",
                sessionLabel: "API key",
                weeklyLabel: "Account plan",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Live Tavily credit usage.",
                toggleTitle: "Show Tavily usage",
                cliName: "tavily",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://app.tavily.com/home",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .tavily),
                iconResourceName: "ProviderIcon-tavily",
                color: ProviderColor(hex: 0xFF7300),
                confettiPalette: [
                    ProviderColor(hex: 0xFF7300),
                    ProviderColor(hex: 0x81B09A),
                    ProviderColor(hex: 0xFFC753),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Tavily reports credits, not token-cost history." }),
            fetchPlan: self.fetchPlan(),
            cli: ProviderCLIConfig(name: "tavily", aliases: ["tvly"], versionDetector: nil))
    }

    private static func fetchPlan() -> ProviderFetchPlan {
        ProviderFetchPlan(
            sourceModes: [.auto, .api],
            pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                [ScriptFetchStrategy(
                    id: "tavily.js",
                    provider: .tavily,
                    bundledPlugin: "tavily",
                    secretKey: TavilySettingsReader.apiKeyEnvironmentKey,
                    sourceLabel: "api",
                    resolveSecret: { environment in
                        self.credentials.resolveToken(environment: environment)?.token
                    },
                    isEnabled: { _ in true })]
            }))
    }
}
