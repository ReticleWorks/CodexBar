import CodexBarCore
import Foundation
import Testing

struct CodexHomeScopeDiscoveryTests {
    @Test
    func `discovers dot-codex homes and dedupes against configured paths`() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        // Already configured — must not be duplicated even though it also matches the on-disk pattern.
        let configuredDir = home.appendingPathComponent(".codex-infra", isDirectory: true)
        try fileManager.createDirectory(at: configuredDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: configuredDir.appendingPathComponent("auth.json"))

        // Undiscovered homes, one plain `.codex` and one `.codex-*` suffix.
        let ambientDir = home.appendingPathComponent(".codex", isDirectory: true)
        try fileManager.createDirectory(at: ambientDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: ambientDir.appendingPathComponent("auth.json"))

        let zetaDir = home.appendingPathComponent(".codex-zzz", isDirectory: true)
        try fileManager.createDirectory(at: zetaDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: zetaDir.appendingPathComponent("auth.json"))

        // No auth.json — must be skipped.
        let emptyDir = home.appendingPathComponent(".codex-empty", isDirectory: true)
        try fileManager.createDirectory(at: emptyDir, withIntermediateDirectories: true)

        // Not a `.codex*` name — must be skipped.
        let unrelatedDir = home.appendingPathComponent(".other", isDirectory: true)
        try fileManager.createDirectory(at: unrelatedDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: unrelatedDir.appendingPathComponent("auth.json"))

        let stubbedHomeFileManager = StubHomeDirectoryFileManager(homeDirectory: home)
        let result = CodexHomeScope.discoveredHomePaths(
            configured: [configuredDir.path],
            fileManager: stubbedHomeFileManager)

        #expect(result == [configuredDir.path, ambientDir.path, zetaDir.path])
    }
}

/// `FileManager.homeDirectoryForCurrentUser` cannot be overridden directly, so this subclass
/// swaps in a temp directory while delegating everything else to the real file manager.
private final class StubHomeDirectoryFileManager: FileManager, @unchecked Sendable {
    private let stubbedHome: URL
    private let real = FileManager.default

    init(homeDirectory: URL) {
        self.stubbedHome = homeDirectory
        super.init()
    }

    override var homeDirectoryForCurrentUser: URL { self.stubbedHome }

    override func contentsOfDirectory(atPath path: String) throws -> [String] {
        try self.real.contentsOfDirectory(atPath: path)
    }

    override func fileExists(atPath path: String) -> Bool {
        self.real.fileExists(atPath: path)
    }

    override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        self.real.fileExists(atPath: path, isDirectory: isDirectory)
    }
}
