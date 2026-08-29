import CodexBarCore
import Foundation

struct TinkerProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .tinker

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "billing api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .tinker, field: .apiKey]
        _ = settings.tokenAccountsData(for: .tinker)
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        TinkerSettingsReader.apiKey(environment: context.environment) != nil ||
            !context.settings[providerConfig: .tinker, field: .apiKey]
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !context.settings.tokenAccounts(for: .tinker).isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [ProviderSettingsFieldDescriptor(
            id: "tinker-api-key",
            title: "Tinker API key",
            subtitle: "Requires billing-view access. Usage can lag by several hours and spans the last 14 days.",
            kind: .secure,
            placeholder: "tml-...",
            binding: context.providerConfigBinding(.apiKey),
            actions: [],
            isVisible: nil,
            onActivate: nil)]
    }
}
