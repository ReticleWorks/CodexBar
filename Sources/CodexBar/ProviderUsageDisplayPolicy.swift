import CodexBarCore

enum ProviderUsageDisplayPolicy {
    static func showsUsed(for provider: UsageProvider, defaultShowUsed: Bool) -> Bool {
        switch provider {
        case .claude:
            true
        case .fireworks:
            true
        case .codex, .amp, .openrouter, .deepinfra:
            false
        default:
            defaultShowUsed
        }
    }
}
