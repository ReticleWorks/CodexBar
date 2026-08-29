import CodexBarCore
import Foundation

struct GoogleAIProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .googleai
    let supportsLoginFlow = true

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        await context.controller.runVertexAILoginFlow()
        return false
    }

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "cloud monitoring" }
    }

    @MainActor
    func observeSettings(_: SettingsStore) {}

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        VertexAIOAuthCredentialsStore.hasCredentials(environment: context.environment)
    }
}
