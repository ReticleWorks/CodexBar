import Foundation

public enum AccountProjectionRowState: String, Sendable {
    case pending
    case live
    case stale
    case error
}

public extension ProviderAccountUsageSnapshot {
    var projectionState: AccountProjectionRowState {
        let hasError = self.error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard self.snapshot != nil else { return hasError ? .error : .pending }
        return hasError ? .stale : .live
    }
}

/// One read-only account surface shared by menus and the floating sidebar.
/// Identity comes from provider discovery or configured accounts. Retained
/// snapshots supply values only; they never create rows.
public struct AccountProjection: Sendable {
    public let provider: UsageProvider
    public let subscriptions: [ProviderAccountUsageSnapshot]
    public let apiSpend: [ProviderAccountUsageSnapshot]
    public let isRefreshing: Bool
    public let lastUpdatedAt: Date?
    public let lastError: String?

    public init(
        provider: UsageProvider,
        subscriptions: [ProviderAccountUsageSnapshot] = [],
        apiSpend: [ProviderAccountUsageSnapshot] = [],
        isRefreshing: Bool = false,
        lastUpdatedAt: Date? = nil,
        lastError: String? = nil)
    {
        self.provider = provider
        self.subscriptions = subscriptions
        self.apiSpend = apiSpend
        self.isRefreshing = isRefreshing
        self.lastUpdatedAt = lastUpdatedAt
            ?? (subscriptions + apiSpend).compactMap { $0.snapshot?.updatedAt }.max()
        self.lastError = lastError
    }

    public var rows: [ProviderAccountUsageSnapshot] {
        self.subscriptions + self.apiSpend
    }

    public static func empty(for provider: UsageProvider) -> Self {
        Self(provider: provider)
    }
}
