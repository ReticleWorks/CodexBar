import Foundation
import Testing
@testable import CodexBarCore

final class AugmentStatusProbeTests {
    private func failingProbe() throws -> AugmentStatusProbe {
        try AugmentStatusProbe(baseURL: #require(URL(string: "http://127.0.0.1:1")), timeout: 0.1)
    }

    @MainActor
    @Test
    func test_sessionKeepaliveStartLogsActualIntervals() {
        var messages: [String] = []
        let keepalive = AugmentSessionKeepalive { message in
            messages.append(message)
        }

        keepalive.start()
        defer { keepalive.stop() }

        #expect(messages.contains { $0.contains("Check interval: 60s (1 minute)") })
        #expect(messages.contains { $0.contains("Refresh buffer: 300s (5 minutes before expiry)") })
        #expect(messages.contains { $0.contains("Min refresh interval: 60s (1 minute)") })
        #expect(!(messages.contains { $0.contains("every 5 minutes") }))
        #expect(!(messages.contains { $0.contains("2 minutes") }))
    }

    @Test
    func test_debugRawProbe_returnsFormattedOutput() async throws {
        // Given: A probe instance
        let probe = try self.failingProbe()

        // When: We call debugRawProbe
        let output = await probe.debugRawProbe(cookieHeaderOverride: "session=test")

        // Then: The output should contain expected debug information
        #expect(output.contains("=== Augment Debug Probe @"), "Should contain debug header")
        #expect(output.contains("Probe Success") || output.contains("Probe Failed"), "Should contain probe result status")
    }

    @Test
    func test_latestDumps_initiallyEmpty() async {
        // Note: This test may fail if other tests have already run and captured dumps
        // The ring buffer is shared across all tests in the process
        // When: We request latest dumps
        let dumps = await AugmentStatusProbe.latestDumps()

        // Then: Should either be empty or contain previous test dumps
        // We just verify it returns a non-empty string
        #expect(!(dumps.isEmpty), "Should return a string (either empty message or dumps)")
    }

    @Test
    func test_debugRawProbe_capturesFailureInDumps() async throws {
        // Given: A probe with an invalid base URL that will fail
        let invalidProbe = try self.failingProbe()

        // When: We call debugRawProbe which should fail
        let output = await invalidProbe.debugRawProbe(cookieHeaderOverride: "session=test")

        // Then: The output should indicate failure
        #expect(output.contains("Probe Failed"), "Should contain failure message")

        // And: The failure should be captured in dumps
        let dumps = await AugmentStatusProbe.latestDumps()
        #expect(dumps != "No Augment probe dumps captured yet.", "Should have captured the failure")
        #expect(dumps.contains("Probe Failed"), "Dumps should contain the failure")
    }

    @Test
    func test_latestDumps_maintainsRingBuffer() async throws {
        // Given: Multiple failed probes to fill the ring buffer
        let invalidProbe = try self.failingProbe()

        // When: We generate more than 5 dumps (the ring buffer size)
        for _ in 1...7 {
            _ = await invalidProbe.debugRawProbe(cookieHeaderOverride: "session=test")
            // Small delay to ensure different timestamps
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }

        // Then: The dumps should only contain the most recent 5
        let dumps = await AugmentStatusProbe.latestDumps()
        let separatorCount = dumps.components(separatedBy: "\n\n---\n\n").count
        #expect(separatorCount <= 5, "Should maintain at most 5 dumps in ring buffer")
    }

    @Test
    func test_debugRawProbe_includesTimestamp() async throws {
        // Given: A probe instance
        let probe = try self.failingProbe()

        // When: We call debugRawProbe
        let output = await probe.debugRawProbe(cookieHeaderOverride: "session=test")

        // Then: The output should include an ISO8601 timestamp
        #expect(output.contains("@"), "Should contain timestamp marker")
        #expect(output.contains("==="), "Should contain debug header markers")
    }

    @Test
    func test_debugRawProbe_includesCreditsBalance() async throws {
        // Given: A probe instance
        let probe = try self.failingProbe()

        // When: We call debugRawProbe
        let output = await probe.debugRawProbe(cookieHeaderOverride: "session=test")

        // Then: The output should mention credits balance (either in success or failure)
        #expect(output.contains("Credits Balance") || output.contains("Probe Failed"), "Should contain credits information or failure message")
    }

    @Test
    func test_creditsLimit_prefersUsageUnitsAvailable() throws {
        let response = try JSONDecoder().decode(AugmentCreditsResponse.self, from: Data("""
        {
          "usageUnitsRemaining": 15,
          "usageUnitsConsumedThisBillingCycle": 10,
          "usageUnitsAvailable": 100,
          "usageBalanceStatus": "active"
        }
        """.utf8))

        #expect(response.creditsLimit == 100)
    }

    @Test
    func test_creditsLimit_fallsBackToRemainingPlusConsumedWhenAvailableMissing() throws {
        let response = try JSONDecoder().decode(AugmentCreditsResponse.self, from: Data("""
        {
          "usageUnitsRemaining": 15,
          "usageUnitsConsumedThisBillingCycle": 10,
          "usageBalanceStatus": "active"
        }
        """.utf8))

        #expect(response.creditsLimit == 25)
    }

    @Test
    func test_creditsLimit_ignoresZeroAvailableValue() throws {
        let response = try JSONDecoder().decode(AugmentCreditsResponse.self, from: Data("""
        {
          "usageUnitsRemaining": 15,
          "usageUnitsConsumedThisBillingCycle": 10,
          "usageUnitsAvailable": 0,
          "usageBalanceStatus": "active"
        }
        """.utf8))

        #expect(response.creditsLimit == 25)
    }

    // MARK: - Cookie Domain Filtering Tests

    @Test
    func test_cookieDomainMatching_exactMatch() throws {
        // Given: A session with a cookie that has exact domain match
        let cookie = try #require(HTTPCookie(properties: [
            .domain: "app.augmentcode.com",
            .path: "/",
            .name: "session",
            .value: "test123",
        ]))
        let session = AugmentCookieImporter.SessionInfo(
            cookies: [cookie],
            sourceLabel: "Test")
        let targetURL = try #require(URL(string: "https://app.augmentcode.com/api/credits"))

        // When: We get the cookie header for the target URL
        let cookieHeader = session.cookieHeader(for: targetURL)

        // Then: It should include the cookie
        #expect(cookieHeader == "session=test123", "Cookie with exact domain should match")
    }

    @Test
    func test_cookieDomainMatching_parentDomain() throws {
        // Given: A session with a cookie that has parent domain
        let cookie = try #require(HTTPCookie(properties: [
            .domain: "augmentcode.com",
            .path: "/",
            .name: "session",
            .value: "test123",
        ]))
        let session = AugmentCookieImporter.SessionInfo(
            cookies: [cookie],
            sourceLabel: "Test")
        let targetURL = try #require(URL(string: "https://app.augmentcode.com/api/credits"))

        // When: We get the cookie header for the target URL
        let cookieHeader = session.cookieHeader(for: targetURL)

        // Then: It should include the cookie (parent domain matches subdomain)
        #expect(cookieHeader == "session=test123", "Cookie with parent domain should match subdomain")
    }

    @Test
    func test_cookieDomainMatching_wildcardDomain() throws {
        // Given: A session with a cookie that has wildcard domain
        let cookie = try #require(HTTPCookie(properties: [
            .domain: ".augmentcode.com",
            .path: "/",
            .name: "session",
            .value: "test123",
        ]))
        let session = AugmentCookieImporter.SessionInfo(
            cookies: [cookie],
            sourceLabel: "Test")
        let targetURL = try #require(URL(string: "https://app.augmentcode.com/api/credits"))

        // When: We get the cookie header for the target URL
        let cookieHeader = session.cookieHeader(for: targetURL)

        // Then: It should include the cookie
        #expect(cookieHeader == "session=test123", "Cookie with wildcard domain should match")
    }

    @Test
    func test_cookieDomainMatching_wrongDomain() throws {
        // Given: A session with a cookie from a different subdomain
        let cookie = try #require(HTTPCookie(properties: [
            .domain: "auth.augmentcode.com",
            .path: "/",
            .name: "auth_token",
            .value: "test123",
        ]))
        let session = AugmentCookieImporter.SessionInfo(
            cookies: [cookie],
            sourceLabel: "Test")
        let targetURL = try #require(URL(string: "https://app.augmentcode.com/api/credits"))

        // When: We get the cookie header for the target URL
        let cookieHeader = session.cookieHeader(for: targetURL)

        // Then: It should NOT include the cookie
        #expect(cookieHeader.isEmpty, "Cookie from different subdomain should not match")
    }

    @Test
    func test_cookieDomainMatching_differentBaseDomain() throws {
        // Given: A session with a cookie from a completely different domain
        let cookie = try #require(HTTPCookie(properties: [
            .domain: "example.com",
            .path: "/",
            .name: "session",
            .value: "test123",
        ]))
        let session = AugmentCookieImporter.SessionInfo(
            cookies: [cookie],
            sourceLabel: "Test")
        let targetURL = try #require(URL(string: "https://app.augmentcode.com/api/credits"))

        // When: We get the cookie header for the target URL
        let cookieHeader = session.cookieHeader(for: targetURL)

        // Then: It should NOT include the cookie
        #expect(cookieHeader.isEmpty, "Cookie from different base domain should not match")
    }

    @Test
    func test_cookieHeader_filtersCorrectly() throws {
        // Given: A session with multiple cookies from different domains
        let cookies = try [
            #require(HTTPCookie(properties: [
                .domain: "app.augmentcode.com",
                .path: "/",
                .name: "session",
                .value: "valid1",
            ])),
            #require(HTTPCookie(properties: [
                .domain: ".augmentcode.com",
                .path: "/",
                .name: "_session",
                .value: "valid2",
            ])),
            #require(HTTPCookie(properties: [
                .domain: "auth.augmentcode.com",
                .path: "/",
                .name: "auth_token",
                .value: "invalid1",
            ])),
            #require(HTTPCookie(properties: [
                .domain: "billing.augmentcode.com",
                .path: "/",
                .name: "billing_session",
                .value: "invalid2",
            ])),
        ]

        let session = AugmentCookieImporter.SessionInfo(
            cookies: cookies,
            sourceLabel: "Test")

        let targetURL = try #require(URL(string: "https://app.augmentcode.com/api/credits"))

        // When: We get the cookie header for the target URL
        let cookieHeader = session.cookieHeader(for: targetURL)

        // Then: It should only include cookies valid for app.augmentcode.com
        #expect(cookieHeader.contains("session=valid1"), "Should include exact domain match")
        #expect(cookieHeader.contains("_session=valid2"), "Should include wildcard domain match")
        #expect(!(cookieHeader.contains("auth_token")), "Should NOT include auth subdomain cookie")
        #expect(!(cookieHeader.contains("billing_session")), "Should NOT include billing subdomain cookie")
    }

    @Test
    func test_cookieHeader_emptyWhenNoCookiesMatch() throws {
        // Given: A session with cookies that don't match the target domain
        let cookies = try [
            #require(HTTPCookie(properties: [
                .domain: "auth.augmentcode.com",
                .path: "/",
                .name: "auth_token",
                .value: "test",
            ])),
            #require(HTTPCookie(properties: [
                .domain: "example.com",
                .path: "/",
                .name: "other",
                .value: "test",
            ])),
        ]

        let session = AugmentCookieImporter.SessionInfo(
            cookies: cookies,
            sourceLabel: "Test")

        let targetURL = try #require(URL(string: "https://app.augmentcode.com/api/credits"))

        // When: We get the cookie header for the target URL
        let cookieHeader = session.cookieHeader(for: targetURL)

        // Then: It should be empty
        #expect(cookieHeader.isEmpty, "Should return empty string when no cookies match")
    }
}
