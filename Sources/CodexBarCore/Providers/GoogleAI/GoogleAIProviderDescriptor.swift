import Foundation

public enum GoogleAIProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .googleai,
            metadata: ProviderMetadata(
                id: .googleai,
                displayName: "Google AI API",
                shortDisplayName: "Google AI",
                sessionLabel: "Requests",
                weeklyLabel: "Input tokens",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Gemini API quota from Google Cloud Monitoring.",
                toggleTitle: "Show Google AI API usage",
                cliName: "googleai",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://aistudio.google.com/usage",
                subscriptionDashboardURL: "https://aistudio.google.com/billing",
                statusPageURL: nil,
                statusLinkURL: "https://status.cloud.google.com"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .googleai),
                iconResourceName: "ProviderIcon-googleai",
                color: ProviderColor(hex: 0x217BFE),
                confettiPalette: [
                    ProviderColor(hex: 0x217BFE),
                    ProviderColor(hex: 0x64B8FB),
                    ProviderColor(hex: 0xBD99FE),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: {
                    "Google AI Studio prepaid balance has no public API. Use the Billing link for the live balance."
                }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .oauth],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [GoogleAIOAuthFetchStrategy()] })),
            cli: ProviderCLIConfig(name: "googleai", aliases: ["geminiapi"], versionDetector: nil))
    }
}

struct GoogleAIOAuthFetchStrategy: ProviderFetchStrategy {
    let id = "googleai.oauth"
    let kind: ProviderFetchKind = .oauth

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        VertexAIOAuthCredentialsStore.hasCredentials(environment: context.env)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        var credentials = try await VertexAIOAuthCredentialsStore.loadForFetch(environment: context.env)
        if credentials.needsRefresh {
            credentials = try await VertexAITokenRefresher.refresh(credentials)
            try VertexAIOAuthCredentialsStore.save(credentials)
        }
        let usage = try await GoogleAIUsageFetcher.fetchUsage(
            accessToken: credentials.accessToken,
            projectID: credentials.projectId)
        return self.makeResult(
            usage: usage.toUsageSnapshot(email: credentials.email, projectID: credentials.projectId),
            sourceLabel: "cloud monitoring")
    }

    func shouldFallback(on error: Error, context _: ProviderFetchContext) -> Bool {
        error is VertexAIOAuthCredentialsError || error is VertexAITokenRefresher.RefreshError
    }
}
