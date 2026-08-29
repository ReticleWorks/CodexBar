import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum GoogleAIUsageError: LocalizedError, Sendable, Equatable {
    case noProject
    case unauthorized
    case forbidden
    case noData
    case apiError(Int)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noProject:
            "No Google Cloud project is configured for Application Default Credentials."
        case .unauthorized:
            "Google Cloud Monitoring rejected the access token."
        case .forbidden:
            "The Google credential cannot read Cloud Monitoring metrics for this project."
        case .noData:
            "No Gemini API Cloud Monitoring data was found for this project."
        case let .apiError(status):
            "Google Cloud Monitoring returned HTTP \(status)."
        case let .parseFailed(message):
            "Could not parse Google AI API usage: \(message)"
        }
    }
}

public struct GoogleAIUsageSnapshot: Sendable {
    public let requestsUsedPercent: Double?
    public let inputTokensUsedPercent: Double?
    public let outputTokensLast24Hours: Int
    public let outputTokensByModel: [(model: String, tokens: Int)]
    public let updatedAt: Date

    public func toUsageSnapshot(email: String?, projectID: String?) -> UsageSnapshot {
        let rows = self.outputTokensByModel.prefix(20).map { model in
            ProviderDetailSection.makeRow(
                label: model.model,
                value: Self.formatted(model.tokens) + " output tokens")
        }
        let section = try? ProviderDetailSection(title: "Last 24 hours by model", rows: rows)
        let details = rows.isEmpty ? [] : section.map { [$0] } ?? []
        return UsageSnapshot(
            primary: self.requestsUsedPercent.map {
                RateWindow(usedPercent: $0, windowMinutes: 1, resetsAt: nil, resetDescription: "Recent quota use")
            },
            secondary: self.inputTokensUsedPercent.map {
                RateWindow(usedPercent: $0, windowMinutes: 1, resetsAt: nil, resetDescription: "Recent quota use")
            },
            details: details,
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .googleai,
                accountEmail: email,
                accountOrganization: projectID,
                loginMethod: "Google Cloud Monitoring"),
            dataConfidence: .exact)
    }

    private static func formatted(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

public enum GoogleAIUsageFetcher {
    private static let monitoringEndpoint = "https://monitoring.googleapis.com/v3/projects"
    private static let recentWindow: TimeInterval = 10 * 60
    private static let dayWindow: TimeInterval = 24 * 60 * 60

    public static func fetchUsage(
        accessToken: String,
        projectID: String?,
        session transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        now: Date = Date()) async throws -> GoogleAIUsageSnapshot
    {
        guard let projectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines), !projectID.isEmpty else {
            throw GoogleAIUsageError.noProject
        }
        let paidRequests = try await self.quotaPercent(
            baseMetric: "quota/generate_requests_per_model",
            accessToken: accessToken,
            projectID: projectID,
            transport: transport,
            now: now)
        let requests = if let paidRequests {
            paidRequests
        } else {
            try await self.quotaPercent(
                baseMetric: "quota/generate_content_free_tier_requests",
                accessToken: accessToken,
                projectID: projectID,
                transport: transport,
                now: now)
        }
        let paidTokens = try await self.quotaPercent(
            baseMetric: "quota/generate_content_paid_tier_input_token_count",
            accessToken: accessToken,
            projectID: projectID,
            transport: transport,
            now: now)
        let tokens = if let paidTokens {
            paidTokens
        } else {
            try await self.quotaPercent(
                baseMetric: "quota/generate_content_free_tier_input_token_count",
                accessToken: accessToken,
                projectID: projectID,
                transport: transport,
                now: now)
        }
        let outputSeries = try await self.fetchSeries(
            metricType: "generativelanguage.googleapis.com/generate_content_usage_output_token_count",
            accessToken: accessToken,
            projectID: projectID,
            window: self.dayWindow,
            aligner: "ALIGN_SUM",
            transport: transport,
            now: now)
        let outputByModel = self.outputTokensByModel(outputSeries)
        if requests == nil, tokens == nil, outputByModel.isEmpty { throw GoogleAIUsageError.noData }
        return GoogleAIUsageSnapshot(
            requestsUsedPercent: requests,
            inputTokensUsedPercent: tokens,
            outputTokensLast24Hours: outputByModel.reduce(0) { $0 + $1.tokens },
            outputTokensByModel: outputByModel,
            updatedAt: now)
    }

    private static func quotaPercent(
        baseMetric: String,
        accessToken: String,
        projectID: String,
        transport: any ProviderHTTPTransport,
        now: Date) async throws -> Double?
    {
        let prefix = "generativelanguage.googleapis.com/"
        let usage = try await self.fetchSeries(
            metricType: prefix + baseMetric + "/usage",
            accessToken: accessToken,
            projectID: projectID,
            window: self.recentWindow,
            aligner: "ALIGN_SUM",
            transport: transport,
            now: now)
        guard !usage.isEmpty else { return nil }
        let limit = try await self.fetchSeries(
            metricType: prefix + baseMetric + "/limit",
            accessToken: accessToken,
            projectID: projectID,
            window: self.recentWindow,
            aligner: "ALIGN_MAX",
            transport: transport,
            now: now)
        var limits: [GoogleAIQuotaKey: Double] = [:]
        for row in limit {
            guard let key = self.quotaKey(row), let value = self.maxValue(row.points), value > 0 else { continue }
            limits[key] = max(limits[key] ?? 0, value)
        }
        return usage.compactMap { row -> Double? in
            guard let key = self.quotaKey(row), let used = self.maxValue(row.points), let cap = limits[key] else {
                return nil
            }
            return min(100, max(0, used / cap * 100))
        }.max()
    }

    private static func fetchSeries(
        metricType: String,
        accessToken: String,
        projectID: String,
        window: TimeInterval,
        aligner: String,
        transport: any ProviderHTTPTransport,
        now: Date) async throws -> [GoogleAITimeSeries]
    {
        var pageToken: String?
        var all: [GoogleAITimeSeries] = []
        let formatter = ISO8601DateFormatter()
        repeat {
            guard var components = URLComponents(
                string: "\(self.monitoringEndpoint)/\(projectID)/timeSeries")
            else {
                throw GoogleAIUsageError.parseFailed("invalid monitoring URL")
            }
            var items = [
                URLQueryItem(name: "filter", value: "metric.type=\"\(metricType)\""),
                URLQueryItem(
                    name: "interval.startTime",
                    value: formatter.string(from: now.addingTimeInterval(-window))),
                URLQueryItem(name: "interval.endTime", value: formatter.string(from: now)),
                URLQueryItem(name: "aggregation.alignmentPeriod", value: "60s"),
                URLQueryItem(name: "aggregation.perSeriesAligner", value: aligner),
                URLQueryItem(name: "view", value: "FULL"),
            ]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            components.queryItems = items
            guard let url = components.url else { throw GoogleAIUsageError.parseFailed("invalid monitoring URL") }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 20
            let response = try await transport.response(for: request)
            switch response.statusCode {
            case 200: break
            case 401: throw GoogleAIUsageError.unauthorized
            case 403: throw GoogleAIUsageError.forbidden
            default: throw GoogleAIUsageError.apiError(response.statusCode)
            }
            let decoded: GoogleAITimeSeriesResponse
            do {
                decoded = try JSONDecoder().decode(GoogleAITimeSeriesResponse.self, from: response.data)
            } catch {
                throw GoogleAIUsageError.parseFailed(error.localizedDescription)
            }
            all.append(contentsOf: decoded.timeSeries ?? [])
            pageToken = decoded.nextPageToken?.isEmpty == false ? decoded.nextPageToken : nil
        } while pageToken != nil
        return all
    }

    private static func outputTokensByModel(_ series: [GoogleAITimeSeries]) -> [(model: String, tokens: Int)] {
        var totals: [String: Double] = [:]
        for row in series {
            let model = row.metric.labels?["model"] ?? "Unknown model"
            totals[model, default: 0] += row.points.compactMap(self.pointValue).reduce(0, +)
        }
        return totals.map { (model: $0.key, tokens: Int($0.value.rounded())) }
            .sorted { $0.tokens > $1.tokens }
    }

    private static func quotaKey(_ series: GoogleAITimeSeries) -> GoogleAIQuotaKey? {
        let labels = series.metric.labels ?? [:]
        let model = labels["model"] ?? ""
        let limitName = labels["limit_name"] ?? ""
        guard !model.isEmpty || !limitName.isEmpty else { return nil }
        return GoogleAIQuotaKey(model: model, limitName: limitName)
    }

    private static func maxValue(_ points: [GoogleAIPoint]) -> Double? {
        points.compactMap(self.pointValue).max()
    }

    private static func pointValue(_ point: GoogleAIPoint) -> Double? {
        point.value.doubleValue ?? point.value.int64Value.flatMap(Double.init)
    }
}

private struct GoogleAIQuotaKey: Hashable {
    let model: String
    let limitName: String
}

private struct GoogleAITimeSeriesResponse: Decodable {
    let timeSeries: [GoogleAITimeSeries]?
    let nextPageToken: String?
}

private struct GoogleAITimeSeries: Decodable {
    let metric: GoogleAIMetric
    let points: [GoogleAIPoint]
}

private struct GoogleAIMetric: Decodable {
    let labels: [String: String]?
}

private struct GoogleAIPoint: Decodable {
    let value: GoogleAIValue
}

private struct GoogleAIValue: Decodable {
    let doubleValue: Double?
    let int64Value: String?
}
