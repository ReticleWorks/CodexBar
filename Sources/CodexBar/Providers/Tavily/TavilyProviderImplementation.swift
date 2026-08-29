import CodexBarCore
import Foundation

struct TavilyProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .tavily

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .tavily, field: .apiKey]
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        TavilySettingsReader.apiKey(environment: context.environment) != nil ||
            !context.settings[providerConfig: .tavily, field: .apiKey]
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [ProviderSettingsFieldDescriptor(
            id: "tavily-api-key",
            title: "API key",
            subtitle: "Stored in the CodexBar config file. Tavily usage is read from the official usage endpoint.",
            kind: .secure,
            placeholder: "tvly-...",
            binding: context.providerConfigBinding(.apiKey),
            actions: [],
            isVisible: nil,
            onActivate: nil)]
    }
}
