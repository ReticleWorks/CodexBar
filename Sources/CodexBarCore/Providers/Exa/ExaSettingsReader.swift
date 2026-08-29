import Foundation

public enum ExaSettingsReader {
    public static let serviceKeyEnvironmentKey = "EXA_SERVICE_API_KEY"

    public static func serviceKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let value = environment[self.serviceKeyEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
