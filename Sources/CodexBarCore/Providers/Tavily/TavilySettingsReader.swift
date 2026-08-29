import Foundation

public enum TavilySettingsReader {
    public static let apiKeyEnvironmentKey = "TAVILY_API_KEY"

    public static func apiKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.cleaned(environment[self.apiKeyEnvironmentKey])
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
