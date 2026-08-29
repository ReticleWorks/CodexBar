#if canImport(JavaScriptCore)
import Foundation
import Testing
@testable import CodexBarCore

struct NewSpendProviderPluginTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `Tavily reports exact key and plan credit use`(engine: ProviderPluginEngineKind) async throws {
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.url?.absoluteString == "https://api.tavily.com/usage")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tavily-test")
            return try Self.response(request: request, body: """
            {"key":{"usage":25,"limit":100},"account":{"plan_usage":200,"plan_limit":1000,
            "paygo_usage":3,"paygo_limit":50,"current_plan":"Research","search_usage":140}}
            """)
        }
        let runtime = try BundledPluginTestSupport.runtime("tavily", engine: engine, transport: transport)

        let snapshot = try await runtime.fetchUsage(secrets: ["TAVILY_API_KEY": "tavily-test"])

        #expect(snapshot.primary?.usedPercent == 25)
        #expect(snapshot.secondary?.usedPercent == 20)
        #expect(snapshot.identity?.loginMethod == "Research")
        #expect(snapshot.dataConfidence == .exact)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `Exa aggregates API key cost and budgets`(engine: ProviderPluginEngineKind) async throws {
        let transport = ProviderHTTPTransportHandler { request in
            let path = request.url?.path
            if path == "/team-management/api-keys" {
                return try Self.response(request: request, body: """
                [{"id":"key-1","name":"production","budgetCents":5000}]
                """)
            }
            #expect(path == "/team-management/api-keys/key-1/usage")
            return try Self.response(request: request, body: """
            {"api_key_name":"production","total_cost_usd":12.5,
            "cost_breakdown":[{"price_name":"search","amount_usd":10},
            {"price_name":"contents","amount_usd":2.5}]}
            """)
        }
        let runtime = try BundledPluginTestSupport.runtime("exa", engine: engine, transport: transport)

        let snapshot = try await runtime.fetchUsage(secrets: ["EXA_SERVICE_API_KEY": "exa-test"])

        #expect(snapshot.primary?.usedPercent == 25)
        #expect(snapshot.providerCost?.used == 12.5)
        #expect(snapshot.providerCost?.limit == 50)
        #expect(snapshot.identity?.loginMethod == "1 API key")
        #expect(snapshot.dataConfidence == .exact)
    }

    private static func response(request: URLRequest, body: String) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]))
        return (Data(body.utf8), response)
    }
}
#endif
