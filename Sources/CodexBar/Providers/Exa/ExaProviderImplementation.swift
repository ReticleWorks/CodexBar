import CodexBarCore
import Foundation

struct ExaProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .exa

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "admin api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .exa, field: .apiKey]
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        ExaSettingsReader.serviceKey(environment: context.environment) != nil ||
            !context.settings[providerConfig: .exa, field: .apiKey]
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [ProviderSettingsFieldDescriptor(
            id: "exa-service-key",
            title: "Service API key",
            subtitle: "Use a team service key. Exa returns authoritative cost for every API key in that team.",
            kind: .secure,
            placeholder: "Service key...",
            binding: context.providerConfigBinding(.apiKey),
            actions: [],
            isVisible: nil,
            onActivate: nil)]
    }
}
