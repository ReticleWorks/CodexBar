import Foundation

public enum TinkerSettingsReader {
    public static let apiKeyEnvironmentKey = "TINKER_API_KEY"

    public static func apiKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let value = environment[self.apiKeyEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
