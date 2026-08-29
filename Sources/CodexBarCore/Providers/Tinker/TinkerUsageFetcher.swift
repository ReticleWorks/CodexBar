import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum TinkerUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case authenticationRejected
    case permissionDenied
    case rateLimited
    case apiError(Int)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing Thinking Machines Tinker API key. Add one in Settings or set TINKER_API_KEY."
        case .authenticationRejected:
            "Thinking Machines rejected the Tinker API key."
        case .permissionDenied:
            "This Tinker account does not have billing-view access."
        case .rateLimited:
            "Thinking Machines rate limited the billing usage request."
        case let .apiError(status):
            "Thinking Machines billing API returned HTTP \(status)."
        case let .parseFailed(message):
            "Could not parse Thinking Machines usage: \(message)"
        }
    }
}

public enum TinkerUsageFetcher {
    private static let eventsURL = "https://tinker.thinkingmachines.dev/services/tinker-prod/api/v1/billing/usage/events"
    private static let pricesURL = "https://tinker-docs.thinkingmachines.ai/tinker/models.json"
    private static let timeoutSeconds: TimeInterval = 20
    private static let historyDays = 14

    public static func fetchUsage(
        apiKey: String,
        session transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        now: Date = Date()) async throws -> UsageSnapshot
    {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TinkerUsageError.missingCredentials }
        let endingBefore = self.hourBoundary(now)
        let startingOn = endingBefore.addingTimeInterval(-TimeInterval(self.historyDays * 24 * 60 * 60))

        let events = try await self.fetchEvents(
            apiKey: key,
            startingOn: startingOn,
            endingBefore: endingBefore,
            transport: transport)
        let prices = await (try? self.fetchPrices(transport: transport)) ?? [:]
        return try self.makeSnapshot(events: events, prices: prices, now: now)
    }

    private static func fetchEvents(
        apiKey: String,
        startingOn: Date,
        endingBefore: Date,
        transport: any ProviderHTTPTransport) async throws -> TinkerBillingUsageResponse
    {
        guard var components = URLComponents(string: self.eventsURL) else {
            throw TinkerUsageError.parseFailed("invalid billing endpoint")
        }
        components.queryItems = [
            URLQueryItem(name: "starting_on", value: self.isoString(startingOn)),
            URLQueryItem(name: "ending_before", value: self.isoString(endingBefore)),
        ]
        guard let url = components.url else { throw TinkerUsageError.parseFailed("invalid billing URL") }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = self.timeoutSeconds
        let response = try await transport.response(for: request)
        switch response.statusCode {
        case 200: break
        case 401: throw TinkerUsageError.authenticationRejected
        case 403: throw TinkerUsageError.permissionDenied
        case 429: throw TinkerUsageError.rateLimited
        default: throw TinkerUsageError.apiError(response.statusCode)
        }
        do {
            return try self.decoder.decode(TinkerBillingUsageResponse.self, from: response.data)
        } catch {
            throw TinkerUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func fetchPrices(
        transport: any ProviderHTTPTransport) async throws -> [String: TinkerModelPrice]
    {
        guard let url = URL(string: self.pricesURL) else {
            throw TinkerUsageError.parseFailed("invalid model-price endpoint")
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = self.timeoutSeconds
        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else { throw TinkerUsageError.apiError(response.statusCode) }
        do {
            let rows = try JSONDecoder().decode([TinkerModelPrice].self, from: response.data)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.tinkerID, $0) })
        } catch {
            throw TinkerUsageError.parseFailed("model prices: \(error.localizedDescription)")
        }
    }

    static func makeSnapshot(
        events: TinkerBillingUsageResponse,
        prices: [String: TinkerModelPrice],
        now: Date) throws -> UsageSnapshot
    {
        var totals = TinkerUsageAccumulator()
        var daily: [String: TinkerUsageAccumulator] = [:]
        for event in events.data {
            let day = String(event.bucketStart.prefix(10))
            var dayValue = daily[day] ?? TinkerUsageAccumulator()
            dayValue.add(event: event, price: event.baseModel.flatMap { prices[$0] })
            daily[day] = dayValue
            totals.add(event: event, price: event.baseModel.flatMap { prices[$0] })
        }

        let dailyEntries = daily.keys.sorted().map { day in
            let value = daily[day]!
            return CostUsageDailyReport.Entry(
                date: day,
                inputTokens: value.inputTokens,
                outputTokens: value.sampleTokens,
                cacheReadTokens: value.cachedPrefillTokens,
                totalTokens: value.totalTokens,
                requestCount: value.eventCount,
                costUSD: value.unpricedTokenEvents == 0 ? value.estimatedCostUSD : nil,
                modelsUsed: value.models.sorted(),
                modelBreakdowns: nil,
                unpricedRequestCount: value.unpricedTokenEvents,
                estimatedRequestCount: value.pricedTokenEvents)
        }
        let exactEstimate = totals.unpricedTokenEvents == 0 ? totals.estimatedCostUSD : nil
        let costUsage = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: totals.totalTokens,
            last30DaysCostUSD: exactEstimate,
            last30DaysRequests: totals.eventCount,
            historyDays: self.historyDays,
            historyLabel: "Last 14 days",
            costProvenance: .listPriceEstimate,
            daily: dailyEntries,
            updatedAt: now)
        let rows = [
            ProviderDetailSection.makeRow(label: "Training", value: self.formatted(totals.trainingTokens) + " tokens"),
            ProviderDetailSection.makeRow(label: "Prefill", value: self.formatted(totals.prefillTokens) + " tokens"),
            ProviderDetailSection.makeRow(
                label: "Cached prefill",
                value: self.formatted(totals.cachedPrefillTokens) + " tokens"),
            ProviderDetailSection.makeRow(label: "Sampling", value: self.formatted(totals.sampleTokens) + " tokens"),
            ProviderDetailSection.makeRow(label: "Checkpoints", value: self.formatted(totals.checkpoints)),
            ProviderDetailSection.makeRow(
                label: "Storage",
                value: String(format: "%.2f GB-hours", totals.storageGigabyteHours)),
            ProviderDetailSection.makeRow(
                label: "Price coverage",
                value: totals.unpricedTokenEvents == 0 ? "All token events" : "Incomplete",
                secondaryValue: totals.unpricedTokenEvents == 0
                    ? "Public list prices; not an invoice"
                    : "\(totals.unpricedTokenEvents) token events could not be priced"),
        ]
        return try UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: exactEstimate.map { estimate in
                ProviderCostSnapshot(
                    used: estimate,
                    limit: 0,
                    currencyCode: "USD",
                    period: "Estimated · last 14 days",
                    updatedAt: now)
            },
            costUsage: costUsage,
            details: [ProviderDetailSection(title: "Billing usage", rows: rows)],
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .tinker,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Billing API · 14 days"),
            dataConfidence: exactEstimate == nil ? .unknown : .estimated)
    }

    private static var decoder: JSONDecoder {
        JSONDecoder()
    }

    private static func hourBoundary(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 3600) * 3600)
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func formatted(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

public struct TinkerBillingUsageResponse: Decodable, Sendable {
    public let data: [TinkerBillingUsageEvent]
}

public struct TinkerBillingUsageEvent: Decodable, Sendable {
    public let bucketStart: String
    public let baseModel: String?
    public let eventInfo: TinkerBillingEventInfo

    private enum CodingKeys: String, CodingKey {
        case bucketStart = "bucket_start"
        case baseModel = "base_model"
        case eventInfo = "event_info"
    }
}

public struct TinkerBillingEventInfo: Decodable, Sendable {
    public let type: String
    public let tokenCount: Int?
    public let cached: Bool?
    public let count: Int?
    public let gigabyteHours: Double?

    private enum CodingKeys: String, CodingKey {
        case type
        case tokenCount = "token_count"
        case cached
        case count
        case gigabyteHours = "gigabyte_hours"
    }
}

public struct TinkerModelPrice: Decodable, Sendable {
    public let tinkerID: String
    public let prefill: String
    public let cachedPrefill: String
    public let sample: String
    public let train: String

    private enum CodingKeys: String, CodingKey {
        case tinkerID = "tinker_id"
        case prefill
        case cachedPrefill = "cached_prefill"
        case sample
        case train
    }

    fileprivate func dollarsPerMillion(for type: String, cached: Bool?) -> Double? {
        let raw: String
        switch type {
        case "training": raw = self.train
        case "sampling_prefill": raw = cached == true ? self.cachedPrefill : self.prefill
        case "sampling_sample": raw = self.sample
        default: return nil
        }
        return Double(raw.trimmingCharacters(in: CharacterSet(charactersIn: "$")))
    }
}

private struct TinkerUsageAccumulator {
    var trainingTokens = 0
    var prefillTokens = 0
    var cachedPrefillTokens = 0
    var sampleTokens = 0
    var checkpoints = 0
    var storageGigabyteHours = 0.0
    var estimatedCostUSD = 0.0
    var eventCount = 0
    var pricedTokenEvents = 0
    var unpricedTokenEvents = 0
    var models: Set<String> = []

    var inputTokens: Int {
        self.trainingTokens + self.prefillTokens - self.cachedPrefillTokens
    }

    var totalTokens: Int {
        self.trainingTokens + self.prefillTokens + self.sampleTokens
    }

    mutating func add(event: TinkerBillingUsageEvent, price: TinkerModelPrice?) {
        self.eventCount += 1
        if let model = event.baseModel { self.models.insert(model) }
        let info = event.eventInfo
        switch info.type {
        case "training": self.trainingTokens += info.tokenCount ?? 0
        case "sampling_prefill":
            self.prefillTokens += info.tokenCount ?? 0
            if info.cached == true { self.cachedPrefillTokens += info.tokenCount ?? 0 }
        case "sampling_sample": self.sampleTokens += info.tokenCount ?? 0
        case "checkpoint": self.checkpoints += info.count ?? 0
        case "storage": self.storageGigabyteHours += info.gigabyteHours ?? 0
        default: break
        }
        guard let tokens = info.tokenCount, tokens > 0 else { return }
        guard let rate = price?.dollarsPerMillion(for: info.type, cached: info.cached) else {
            self.unpricedTokenEvents += 1
            return
        }
        self.pricedTokenEvents += 1
        self.estimatedCostUSD += Double(tokens) / 1_000_000 * rate
    }
}
