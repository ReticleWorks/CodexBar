import Foundation
import Testing
@testable import CodexBarCore

struct TinkerUsageFetcherTests {
    @Test
    func `builds list price estimate without double counting cached prefill`() throws {
        let eventsJSON = """
        {"data":[
          {"bucket_start":"2026-08-28T00:00:00Z","base_model":"alpha","event_info":{"type":"training","token_count":1000000}},
          {"bucket_start":"2026-08-28T01:00:00Z","base_model":"alpha","event_info":{"type":"sampling_prefill","token_count":2000000,"cached":false}},
          {"bucket_start":"2026-08-28T02:00:00Z","base_model":"alpha","event_info":{"type":"sampling_prefill","token_count":3000000,"cached":true}},
          {"bucket_start":"2026-08-28T03:00:00Z","base_model":"alpha","event_info":{"type":"sampling_sample","token_count":4000000}}
        ]}
        """
        let pricesJSON = """
        [{"tinker_id":"alpha","prefill":"$2","cached_prefill":"$1","sample":"$4","train":"$3"}]
        """
        let events = try JSONDecoder().decode(TinkerBillingUsageResponse.self, from: Data(eventsJSON.utf8))
        let prices = try JSONDecoder().decode([TinkerModelPrice].self, from: Data(pricesJSON.utf8))
        let now = Date(timeIntervalSince1970: 1_787_968_800)

        let snapshot = try TinkerUsageFetcher.makeSnapshot(
            events: events,
            prices: ["alpha": prices[0]],
            now: now)

        #expect(snapshot.costUsage?.last30DaysTokens == 10_000_000)
        #expect(snapshot.costUsage?.last30DaysCostUSD == 26)
        #expect(snapshot.costUsage?.costProvenance == .listPriceEstimate)
        #expect(snapshot.costUsage?.daily.first?.inputTokens == 3_000_000)
        #expect(snapshot.costUsage?.daily.first?.cacheReadTokens == 3_000_000)
        #expect(snapshot.dataConfidence == .estimated)
    }

    @Test
    func `keeps raw usage when public pricing lacks a model`() throws {
        let json = """
        {"data":[
          {"bucket_start":"2026-08-28T00:00:00Z","base_model":"unknown","event_info":{"type":"sampling_sample","token_count":12}}
        ]}
        """
        let events = try JSONDecoder().decode(TinkerBillingUsageResponse.self, from: Data(json.utf8))

        let snapshot = try TinkerUsageFetcher.makeSnapshot(events: events, prices: [:], now: Date())

        #expect(snapshot.costUsage?.last30DaysTokens == 12)
        #expect(snapshot.costUsage?.last30DaysCostUSD == nil)
        #expect(snapshot.providerCost == nil)
        #expect(snapshot.dataConfidence == .unknown)
    }
}
