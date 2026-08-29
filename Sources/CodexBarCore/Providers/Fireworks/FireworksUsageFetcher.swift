import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct FireworksUsageSnapshot: Sendable {
    public let summary: FireworksUsageSummary
    public let accountSlug: String
    public let accountSlugWasDiscovered: Bool

    public init(
        summary: FireworksUsageSummary,
        accountSlug: String = "",
        accountSlugWasDiscovered: Bool = false)
    {
        self.summary = summary
        self.accountSlug = accountSlug
        self.accountSlugWasDiscovered = accountSlugWasDiscovered
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        self.summary.toUsageSnapshot()
    }
}

public struct FireworksUsageSummary: Sendable {
    /// Exact rated subtotal returned by Fireworks for the last 30 days.
    public let last30DaysSpend: Double?
    public let currencyCode: String?
    public let dailyCosts: [FireworksDailyCost]
    public let updatedAt: Date

    public init(
        last30DaysSpend: Double?,
        currencyCode: String?,
        dailyCosts: [FireworksDailyCost] = [],
        updatedAt: Date)
    {
        self.last30DaysSpend = last30DaysSpend
        self.currencyCode = currencyCode
        self.dailyCosts = dailyCosts
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let costUsage: CostUsageTokenSnapshot? = if let last30DaysSpend, let currencyCode {
            CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: nil,
                last30DaysCostUSD: last30DaysSpend,
                currencyCode: currencyCode,
                historyDays: 30,
                historyLabel: "Rated usage · last 30 days",
                costProvenance: .vendorMetered,
                daily: self.dailyCosts.map { day in
                    CostUsageDailyReport.Entry(
                        date: day.date,
                        inputTokens: nil,
                        outputTokens: nil,
                        totalTokens: nil,
                        requestCount: nil,
                        costUSD: day.cost,
                        modelsUsed: day.models.map(\.name),
                        modelBreakdowns: day.models.map { model in
                            CostUsageDailyReport.ModelBreakdown(
                                modelName: model.name,
                                costUSD: model.cost,
                                totalTokens: nil,
                                requestCount: nil)
                        },
                        pricedRequestCount: 1)
                },
                updatedAt: self.updatedAt)
        } else {
            nil
        }
        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: self.last30DaysSpend.flatMap { spend in
                self.currencyCode.map { code in
                    ProviderCostSnapshot(
                        used: spend,
                        limit: 0,
                        currencyCode: code,
                        period: "Last 30 days",
                        updatedAt: self.updatedAt)
                }
            },
            costUsage: costUsage,
            updatedAt: self.updatedAt,
            identity: nil)
    }
}

public struct FireworksDailyCost: Sendable, Equatable {
    public struct ModelCost: Sendable, Equatable {
        public let name: String
        public let cost: Double

        public init(name: String, cost: Double) {
            self.name = name
            self.cost = cost
        }
    }

    public let date: String
    public let cost: Double
    public let models: [ModelCost]

    public init(date: String, cost: Double, models: [ModelCost]) {
        self.date = date
        self.cost = cost
        self.models = models
    }
}

public enum FireworksUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case invalidAccountSlug(String)
    case accountNotFound(String)
    case noAccountsFound
    case multipleAccountsFound([String])
    case authenticationRejected
    case rateLimited
    case apiError(Int)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing Fireworks API key. Add one in Settings or set FIREWORKS_API_KEY."
        case let .invalidAccountSlug(slug):
            "Invalid Fireworks account slug '\(slug)'. Please double-check the account slug in Settings."
        case let .accountNotFound(slug):
            "Fireworks account slug '\(slug)' not found for this API key. Leave the slug blank to auto-discover "
                + "it, choose it in the app.fireworks.ai account switcher, or run 'firectl whoami'."
        case .noAccountsFound:
            "No Fireworks accounts are visible to this API key. Check the key in app.fireworks.ai or run "
                + "'firectl whoami'."
        case let .multipleAccountsFound(slugs):
            "This Fireworks API key can access multiple accounts: \(slugs.joined(separator: ", ")). Set the "
                + "account slug in Settings or FIREWORKS_ACCOUNT_SLUG; find it in the app.fireworks.ai account "
                + "switcher or with 'firectl whoami'."
        case .authenticationRejected:
            "Fireworks rejected the API key. Create a new key at app.fireworks.ai and update Settings."
        case .rateLimited:
            "Fireworks rate limit exceeded. Usage will refresh on the next cycle."
        case let .apiError(statusCode):
            "Fireworks billing API returned HTTP \(statusCode)."
        case let .parseFailed(message):
            "Could not parse Fireworks usage: \(message)"
        }
    }
}

public struct FireworksUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.provider(.fireworks, scope: "usage"))
    private static let timeoutSeconds: TimeInterval = 15
    /// Fireworks billing windows are tied to calendar days; a 30-day lookback matches the
    /// card's "Last 30 days" period.
    private static let lookbackDays = 30

    public static func fetchUsage(
        apiKey: String,
        accountSlug: String?,
        session transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        now: Date = Date()) async throws -> FireworksUsageSnapshot
    {
        let cleanedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedKey.isEmpty else {
            throw FireworksUsageError.missingCredentials
        }
        let cleanedSlug = accountSlug?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleanedSlug, !cleanedSlug.isEmpty {
            return try await self.fetchConfiguredAccount(
                apiKey: cleanedKey,
                accountSlug: cleanedSlug,
                transport: transport,
                now: now)
        }

        let slugs = try await self.listAccountSlugs(apiKey: cleanedKey, transport: transport)
        let discoveredSlug = try self.singleDiscoveredAccount(from: slugs)
        let summary = try await self.fetchSummary(
            apiKey: cleanedKey,
            accountSlug: discoveredSlug,
            transport: transport,
            now: now)
        return FireworksUsageSnapshot(
            summary: summary,
            accountSlug: discoveredSlug,
            accountSlugWasDiscovered: true)
    }

    private static func fetchConfiguredAccount(
        apiKey: String,
        accountSlug: String,
        transport: any ProviderHTTPTransport,
        now: Date) async throws -> FireworksUsageSnapshot
    {
        do {
            let summary = try await self.fetchSummary(
                apiKey: apiKey,
                accountSlug: accountSlug,
                transport: transport,
                now: now)
            if summary.last30DaysSpend == nil {
                let slugs = try await self.listAccountSlugs(apiKey: apiKey, transport: transport)
                guard slugs.contains(accountSlug) else {
                    throw FireworksUsageError.accountNotFound(accountSlug)
                }
            }
            return FireworksUsageSnapshot(summary: summary, accountSlug: accountSlug)
        } catch FireworksUsageError.apiError(404) {
            let slugs = try await self.listAccountSlugs(apiKey: apiKey, transport: transport)
            guard slugs.count == 1, let discoveredSlug = slugs.first else {
                if slugs.isEmpty {
                    throw FireworksUsageError.accountNotFound(accountSlug)
                }
                throw FireworksUsageError.multipleAccountsFound(slugs)
            }
            let summary = try await self.fetchSummary(
                apiKey: apiKey,
                accountSlug: discoveredSlug,
                transport: transport,
                now: now)
            return FireworksUsageSnapshot(
                summary: summary,
                accountSlug: discoveredSlug,
                accountSlugWasDiscovered: discoveredSlug != accountSlug)
        }
    }

    private static func fetchSummary(
        apiKey: String,
        accountSlug: String,
        transport: any ProviderHTTPTransport,
        now: Date) async throws -> FireworksUsageSummary
    {
        try await self.queryUsageCosts(
            apiKey: apiKey,
            accountSlug: accountSlug,
            transport: transport,
            now: now)
    }

    private static func listAccountSlugs(
        apiKey: String,
        transport: any ProviderHTTPTransport) async throws -> [String]
    {
        var slugs: Set<String> = []
        var pageToken: String?
        repeat {
            var request = URLRequest(url: self.resolveAccountsURL(pageToken: pageToken))
            self.authorize(&request, apiKey: apiKey, method: "GET")
            let response = try await transport.response(for: request)
            switch response.statusCode {
            case 200:
                break
            case 401, 403:
                throw FireworksUsageError.authenticationRejected
            case 429:
                throw FireworksUsageError.rateLimited
            default:
                Self.log.error("Fireworks accounts API returned HTTP \(response.statusCode)")
                throw FireworksUsageError.apiError(response.statusCode)
            }

            let page: FireworksAccountsResponse
            do {
                page = try JSONDecoder().decode(FireworksAccountsResponse.self, from: response.data)
            } catch {
                throw FireworksUsageError.parseFailed(error.localizedDescription)
            }
            for account in page.accounts ?? [] {
                if let slug = account.slug, self.isValidAccountSlug(slug) {
                    slugs.insert(slug)
                }
            }
            pageToken = page.nextPageToken?.trimmingCharacters(in: .whitespacesAndNewlines)
            if pageToken?.isEmpty == true {
                pageToken = nil
            }
        } while pageToken != nil
        return slugs.sorted()
    }

    private static func singleDiscoveredAccount(from slugs: [String]) throws -> String {
        guard !slugs.isEmpty else {
            throw FireworksUsageError.noAccountsFound
        }
        guard slugs.count == 1, let slug = slugs.first else {
            throw FireworksUsageError.multipleAccountsFound(slugs)
        }
        return slug
    }

    private static func authorize(_ request: inout URLRequest, apiKey: String, method: String) {
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = self.timeoutSeconds
    }

    private static func queryUsageCosts(
        apiKey: String,
        accountSlug: String,
        transport: any ProviderHTTPTransport,
        now: Date) async throws -> FireworksUsageSummary
    {
        let startTime = now.addingTimeInterval(-TimeInterval(self.lookbackDays * 24 * 60 * 60))
        let url = try self.resolveUsageCostsURL(accountSlug: accountSlug)
        var pageToken: String?
        var rows: [FireworksUsageCostRow] = []
        var subtotal: FireworksMoney?
        repeat {
            var request = URLRequest(url: url)
            self.authorize(&request, apiKey: apiKey, method: "POST")
            var body: [String: Any] = [
                "startTime": self.isoString(startTime),
                "endTime": self.isoString(now),
                "scope": "ACCOUNT",
                "groupBy": ["DAY", "MODEL"],
                "pageSize": 1000,
            ]
            if let pageToken { body["pageToken"] = pageToken }
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            let response = try await transport.response(for: request)
            switch response.statusCode {
            case 200: break
            case 401, 403: throw FireworksUsageError.authenticationRejected
            case 429: throw FireworksUsageError.rateLimited
            default:
                Self.log.error("Fireworks usage-cost API returned HTTP \(response.statusCode)")
                throw FireworksUsageError.apiError(response.statusCode)
            }
            let page: FireworksUsageCostsResponse
            do {
                page = try JSONDecoder().decode(FireworksUsageCostsResponse.self, from: response.data)
            } catch {
                throw FireworksUsageError.parseFailed(error.localizedDescription)
            }
            rows.append(contentsOf: page.rows ?? [])
            if subtotal == nil { subtotal = page.subtotal }
            pageToken = page.nextPageToken?.trimmingCharacters(in: .whitespacesAndNewlines)
            if pageToken?.isEmpty == true { pageToken = nil }
        } while pageToken != nil
        return try self.makeUsageCostSummary(rows: rows, subtotal: subtotal, now: now)
    }

    public static func resolveUsageCostsURL(accountSlug: String) throws -> URL {
        guard self.isValidAccountSlug(accountSlug),
              let url = URL(
                  string: "https://api.fireworks.ai/v1/accounts/\(accountSlug)/usageCosts:query")
        else {
            throw FireworksUsageError.invalidAccountSlug(accountSlug)
        }
        return url
    }

    static func _parseUsageCostsForTesting(_ data: Data, now: Date = Date()) throws -> FireworksUsageSummary {
        let response: FireworksUsageCostsResponse
        do {
            response = try JSONDecoder().decode(FireworksUsageCostsResponse.self, from: data)
        } catch {
            throw FireworksUsageError.parseFailed(error.localizedDescription)
        }
        return try self.makeUsageCostSummary(
            rows: response.rows ?? [],
            subtotal: response.subtotal,
            now: now)
    }

    private static func makeUsageCostSummary(
        rows: [FireworksUsageCostRow],
        subtotal: FireworksMoney?,
        now: Date) throws -> FireworksUsageSummary
    {
        let subtotalCurrency = subtotal?.currencyCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        var byDay: [String: [String: Double]] = [:]
        for row in rows {
            guard let start = row.dimensions?.startTime, start.count >= 10 else { continue }
            let day = String(start.prefix(10))
            let model = row.dimensions?.model?.split(separator: "/").last.map(String.init) ?? "Unknown model"
            let value = try self.moneyValue(row.subtotal) ?? 0
            byDay[day, default: [:]][model, default: 0] += value
        }
        let daily = byDay.keys.sorted().map { day in
            let models = byDay[day, default: [:]].map { name, cost in
                FireworksDailyCost.ModelCost(name: name, cost: cost)
            }.sorted { $0.cost > $1.cost }
            return FireworksDailyCost(date: day, cost: models.reduce(0) { $0 + $1.cost }, models: models)
        }
        let rowCurrency = rows.compactMap { row in
            row.subtotal?.currencyCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.first { !$0.isEmpty }
        let currency = subtotalCurrency.flatMap { $0.isEmpty ? nil : $0 } ?? rowCurrency
        let total = try self.moneyValue(subtotal) ?? (daily.isEmpty ? nil : daily.reduce(0) { $0 + $1.cost })
        return FireworksUsageSummary(
            last30DaysSpend: total,
            currencyCode: currency,
            dailyCosts: daily,
            updatedAt: now)
    }

    private static func moneyValue(_ money: FireworksMoney?) throws -> Double? {
        guard let money else { return nil }
        guard let units = Double(money.units ?? "0") else {
            throw FireworksUsageError.parseFailed("invalid money value")
        }
        return units + Double(money.nanos ?? 0) / 1_000_000_000
    }

    /// Characters permitted in a Fireworks account slug. Fireworks slugs are simple
    /// lower-case ASCII path segments (alnum plus `-`, `_`, `.`); restricting to this explicit
    /// ASCII set means a misconfigured slug can never widen the request path, inject a query,
    /// or crash on URL construction, and every allowed character is already URL-safe in a
    /// single path segment (no encoding needed).
    private static let accountSlugAllowedCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    private static func isValidAccountSlug(_ slug: String) -> Bool {
        !slug.isEmpty && slug.rangeOfCharacter(from: self.accountSlugAllowedCharacters.inverted) == nil
    }

    public static func resolveAccountsURL(pageToken: String? = nil) -> URL {
        var components = URLComponents(string: "https://api.fireworks.ai/v1/accounts")!
        if let pageToken {
            components.queryItems = [URLQueryItem(name: "pageToken", value: pageToken)]
        }
        return components.url!
    }

    /// `https://api.fireworks.ai/v1/accounts/<slug>/billing/summary` with an explicit
    /// 30-day `startTime`/`endTime` window.
    /// - Throws: `FireworksUsageError.invalidAccountSlug` if the slug cannot be embedded
    ///   safely, so a bad slug surfaces as a config error rather than a URL-construction crash.
    public static func resolveSummaryURL(
        accountSlug: String,
        startTime: Date? = nil,
        endTime: Date? = nil) throws -> URL
    {
        guard accountSlug.rangeOfCharacter(from: self.accountSlugAllowedCharacters.inverted) == nil else {
            throw FireworksUsageError.invalidAccountSlug(accountSlug)
        }
        guard let components = URLComponents(
            string: "https://api.fireworks.ai/v1/accounts/\(accountSlug)/billing/summary")
        else {
            throw FireworksUsageError.invalidAccountSlug(accountSlug)
        }
        var built = components
        var query: [URLQueryItem] = []
        if let startTime {
            query.append(URLQueryItem(name: "startTime", value: Self.isoString(startTime)))
        }
        if let endTime {
            query.append(URLQueryItem(name: "endTime", value: Self.isoString(endTime)))
        }
        built.queryItems = query.isEmpty ? nil : query
        guard let url = built.url else {
            throw FireworksUsageError.invalidAccountSlug(accountSlug)
        }
        return url
    }

    static func _parseSummaryForTesting(_ data: Data, now: Date = Date()) throws -> FireworksUsageSummary {
        try self.parseSummary(data: data, now: now)
    }

    private static func parseSummary(data: Data, now: Date) throws -> FireworksUsageSummary {
        let response: FireworksBillingSummaryResponse
        do {
            response = try JSONDecoder().decode(FireworksBillingSummaryResponse.self, from: data)
        } catch {
            throw FireworksUsageError.parseFailed(error.localizedDescription)
        }

        // Rated line items arrive grouped by category/model; the newest-rated currency
        // decides the display currency and only rows in that currency are summed.
        var currency: String?
        var total = 0.0
        for item in response.lineItems ?? [] {
            guard let cost = item.totalCost,
                  let units = cost.units.flatMap(Double.init),
                  let nanos = cost.nanos,
                  let code = cost.currencyCode?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                      !code.isEmpty
            else {
                continue
            }
            if currency == nil {
                currency = code
            }
            guard code == currency else { continue }
            total += units + Double(nanos) / 1_000_000_000
        }

        return FireworksUsageSummary(
            last30DaysSpend: currency.map { _ in total },
            currencyCode: currency,
            updatedAt: now)
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private struct FireworksBillingSummaryResponse: Decodable {
    let lineItems: [FireworksLineItem]?
    let usageBuckets: [FireworksUsageBucket]?
}

private struct FireworksUsageCostsResponse: Decodable {
    let rows: [FireworksUsageCostRow]?
    let nextPageToken: String?
    let subtotal: FireworksMoney?
}

private struct FireworksUsageCostRow: Decodable {
    let dimensions: FireworksUsageCostDimensions?
    let subtotal: FireworksMoney?
}

private struct FireworksUsageCostDimensions: Decodable {
    let startTime: String?
    let model: String?
}

private struct FireworksAccountsResponse: Decodable {
    let accounts: [FireworksAccount]?
    let nextPageToken: String?
}

private struct FireworksAccount: Decodable {
    let name: String?
    let accountId: String?
    let id: String?

    var slug: String? {
        for value in [self.accountId, self.id, self.name] {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                continue
            }
            return value.split(separator: "/").last.map(String.init)
        }
        return nil
    }
}

private struct FireworksLineItem: Decodable {
    let category: String?
    let groupingKey: String?
    let groupingValue: String?
    let quantity: Double?
    let series: String?
    let totalCost: FireworksMoney?
    let unitAmount: FireworksMoney?
}

private struct FireworksMoney: Decodable {
    let currencyCode: String?
    let nanos: Int?
    let units: String?
}

private struct FireworksUsageBucket: Decodable {
    let bucketStartTime: String?
    let lineItems: [FireworksLineItem]?
}
