import CodexBarCore
import Foundation
import Testing

struct CodexCredentialMirrorTests {
    @Test
    func `mirrors the newest live home per account and fills the gap once a live home disappears`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let mirrorRoot = root.appendingPathComponent("mirror", isDirectory: true)

        // Two live homes share account A; the second is the newer login.
        let homeA1 = root.appendingPathComponent("dot-codex", isDirectory: true)
        let homeA2 = root.appendingPathComponent("dot-codex-harness", isDirectory: true)
        let homeB = root.appendingPathComponent("dot-codex-satchmo", isDirectory: true)
        try Self.writeAuthFile(home: homeA1, accountId: "acct-a", lastRefresh: "2026-08-20T00:00:00Z")
        try Self.writeAuthFile(home: homeA2, accountId: "acct-a", lastRefresh: "2026-08-24T00:00:00Z")
        try Self.writeAuthFile(home: homeB, accountId: "acct-b", lastRefresh: "2026-08-21T00:00:00Z")

        let firstPlan = CodexCredentialMirror.mirrorPlan(
            liveHomes: [homeA1, homeA2, homeB], mirrorRoot: mirrorRoot, fileManager: fileManager)
        #expect(firstPlan.extraHomes.isEmpty)
        #expect(firstPlan.copies.count == 2)
        #expect(firstPlan.copies.contains { $0.from == homeA2.appendingPathComponent("auth.json") })
        #expect(firstPlan.copies.contains { $0.from == homeB.appendingPathComponent("auth.json") })
        CodexCredentialMirror.apply(copies: firstPlan.copies, fileManager: fileManager)

        let mirroredA = try Data(contentsOf: mirrorRoot.appendingPathComponent("acct-a/auth.json"))
        #expect(try CodexOAuthCredentialsStore.parse(data: mirroredA).lastRefresh
            == Self.date("2026-08-24T00:00:00Z"))

        // Re-running immediately (nothing changed) must not propose stale re-copies.
        let secondPlan = CodexCredentialMirror.mirrorPlan(
            liveHomes: [homeA1, homeA2, homeB], mirrorRoot: mirrorRoot, fileManager: fileManager)
        #expect(secondPlan.copies.isEmpty)
        #expect(secondPlan.extraHomes.isEmpty)

        // B's only live home disappears (e.g. a re-login overwrote it with a different account).
        try fileManager.removeItem(at: homeB)
        let thirdPlan = CodexCredentialMirror.mirrorPlan(
            liveHomes: [homeA1, homeA2], mirrorRoot: mirrorRoot, fileManager: fileManager)
        #expect(thirdPlan.extraHomes == [mirrorRoot.appendingPathComponent("acct-b", isDirectory: true)])
        #expect(!thirdPlan.extraHomes.contains(mirrorRoot.appendingPathComponent("acct-a", isDirectory: true)))
    }

    private static func writeAuthFile(home: URL, accountId: String, lastRefresh: String) throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let json: [String: Any] = [
            "tokens": [
                "access_token": "access-token",
                "refresh_token": "refresh-token",
                "account_id": accountId,
            ],
            "last_refresh": lastRefresh,
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: home.appendingPathComponent("auth.json"))
    }

    private static func date(_ iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }
}
