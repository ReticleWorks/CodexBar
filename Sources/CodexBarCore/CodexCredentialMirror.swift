import Foundation

/// Mirrors every live Codex home's `auth.json` into a per-account backup directory so that a
/// `codex login` in one home does not silently erase another account's only surviving token
/// lineage. Live homes always win: this never writes into a live home, and a mirror directory is
/// read back as an extra profile home only while no live home currently holds that account.
public enum CodexCredentialMirror {
    /// One planned copy from a live home's `auth.json` to its per-account mirror path.
    public typealias PlannedCopy = (from: URL, to: URL)

    /// `copies`: mirror files to (over)write because the live copy is newer.
    /// `extraHomes`: mirror directories to treat as additional profile homes because no live
    /// home currently holds that account.
    public static func mirrorPlan(
        liveHomes: [URL],
        mirrorRoot: URL,
        fileManager: FileManager = .default)
        -> (copies: [PlannedCopy], extraHomes: [URL])
    {
        struct LiveEntry { let home: URL; let accountId: String; let timestamp: Date? }

        // Several live homes can share one account (e.g. re-logins into different `.codex-*`
        // dirs). Keep only the newest per account so we mirror from, and compare against, one.
        var newestByAccount: [String: LiveEntry] = [:]
        for home in liveHomes {
            guard let identity = self.identity(
                at: home.appendingPathComponent("auth.json", isDirectory: false),
                fileManager: fileManager)
            else { continue }
            let candidate = LiveEntry(home: home, accountId: identity.accountId, timestamp: identity.timestamp)
            if let existing = newestByAccount[identity.accountId] {
                if self.isNewer(candidate.timestamp, than: existing.timestamp) {
                    newestByAccount[identity.accountId] = candidate
                }
            } else {
                newestByAccount[identity.accountId] = candidate
            }
        }

        var copies: [PlannedCopy] = []
        for (accountId, entry) in newestByAccount.sorted(by: { $0.key < $1.key }) {
            let mirrorAuth = mirrorRoot
                .appendingPathComponent(accountId, isDirectory: true)
                .appendingPathComponent("auth.json", isDirectory: false)
            let mirrorTimestamp = self.identity(at: mirrorAuth, fileManager: fileManager)?.timestamp
            guard mirrorTimestamp == nil || self.isNewer(entry.timestamp, than: mirrorTimestamp) else { continue }
            copies.append((from: entry.home.appendingPathComponent("auth.json", isDirectory: false), to: mirrorAuth))
        }

        let liveAccountIds = Set(newestByAccount.keys)
        var extraHomes: [URL] = []
        let mirrorDirNames = ((try? fileManager.contentsOfDirectory(atPath: mirrorRoot.path)) ?? []).sorted()
        for name in mirrorDirNames where !liveAccountIds.contains(name) {
            let dir = mirrorRoot.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: dir.appendingPathComponent("auth.json").path) else { continue }
            extraHomes.append(dir)
        }

        return (copies, extraHomes)
    }

    /// Applies a plan's copies. Never called with a live-home destination — `mirrorPlan` only
    /// ever proposes mirror-root destinations.
    public static func apply(copies: [PlannedCopy], fileManager: FileManager = .default) {
        for copy in copies {
            guard let data = try? Data(contentsOf: copy.from) else { continue }
            try? fileManager.createDirectory(
                at: copy.to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? CredentialFileWriter.writePrivate(data, to: copy.to)
        }
    }

    /// `account_id` plus a comparable freshness timestamp: `last_refresh` from the auth file,
    /// falling back to the file's modification time when the file has none.
    private static func identity(
        at authURL: URL,
        fileManager: FileManager)
        -> (accountId: String, timestamp: Date?)?
    {
        guard let data = try? Data(contentsOf: authURL),
              let credentials = try? CodexOAuthCredentialsStore.parse(data: data),
              let accountId = credentials.accountId
        else { return nil }
        let timestamp = credentials.lastRefresh ?? self.modificationDate(of: authURL, fileManager: fileManager)
        return (accountId, timestamp)
    }

    private static func modificationDate(of url: URL, fileManager: FileManager) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static func isNewer(_ candidate: Date?, than current: Date?) -> Bool {
        guard let candidate else { return false }
        guard let current else { return true }
        return candidate > current
    }
}
