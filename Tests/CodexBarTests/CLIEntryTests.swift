import CodexBarCore
import Commander
import Foundation
import Testing
@testable import CodexBarCLI

final class CLIEntryTests {
    @Test
    func test_effectiveArgvDefaultsToUsage() {
        #expect(CodexBarCLI.effectiveArgv([]) == ["usage"])
        #expect(CodexBarCLI.effectiveArgv(["--json"]) == ["usage", "--json"])
        #expect(CodexBarCLI.effectiveArgv(["usage", "--json"]) == ["usage", "--json"])
    }

    @Test
    func test_rootHelpAdvertisesDashboardSnapshotCommand() {
        let help = CodexBarCLI.rootHelp(version: "0.0.0")

        #expect(help.contains("codexbar dashboard [--pretty] [--timeout <seconds>] [--output <path>]"))
    }

    @Test
    func test_dashboardCommandIsRegisteredAndParsesOptions() throws {
        let program = Program(descriptors: CodexBarCLI.commandDescriptors())
        let invocation = try program.resolve(
            argv: ["dashboard", "--pretty", "--timeout", "45", "--output", "/tmp/snapshot.json"])

        #expect(invocation.path == ["dashboard"])
        #expect(invocation.parsedValues.flags.contains("pretty"))
        #expect(invocation.parsedValues.options["timeout"] == ["45"])
        #expect(invocation.parsedValues.options["output"] == ["/tmp/snapshot.json"])
    }

    @Test
    func test_dashboardTimeoutIsBoundedAndCanBeDisabled() {
        #expect(CodexBarCLI.decodeDashboardTimeout(from: ParsedValues(positional: [], options: [:], flags: [])) == 30)
        #expect(CodexBarCLI.decodeDashboardTimeout(
                from: ParsedValues(positional: [], options: ["timeout": ["0"]], flags: [])) == 0)
        #expect(CodexBarCLI.decodeDashboardTimeout(
                from: ParsedValues(positional: [], options: ["timeout": ["86400"]], flags: [])) == 86400)

        for value in ["-1", "nan", "inf", "86401"] {
            #expect(CodexBarCLI.decodeDashboardTimeout(
                from: ParsedValues(positional: [], options: ["timeout": [value]], flags: [])) == nil)
        }
    }

    @Test
    func test_dashboardCommanderErrorsStayOffStdout() throws {
        let result = try Self.runCLI(arguments: ["dashboard", "--json"])

        #expect(result.status != 0)
        #expect(result.stdout.isEmpty)
        #expect(!(result.stderr.isEmpty))
    }

    /// `Program.resolve` throws before `ParsedValues` (and `resolveUsageOutputPreferences`) exist, so
    /// a genuine parse failure -- an unrecognized option here -- has to go through the argv-level
    /// `CLIOutputPreferences.from(argv:)` bootstrap scanner. Regression test for that scanner not
    /// recognizing `--format toon` and silently falling back to plain stderr text.
    @Test
    func test_usageCommanderParseFailureWithToonAndJSONRendersTOON() throws {
        let result = try Self.runCLI(arguments: ["usage", "--format", "toon", "--json", "--bogus-flag-xyz"])

        #expect(result.status != 0)
        #expect(result.stderr.isEmpty)
        let stdout = try #require(String(bytes: result.stdout, encoding: .utf8))
        #expect(stdout.contains("- provider: cli"))
        #expect(stdout.contains("Unknown option --bogus-flag-xyz"))
        #expect(!(stdout.hasPrefix("[{")), "TOON error output should not fall back to a JSON array literal")
    }

    @Test
    func test_usageCommanderParseFailureRendersTOONWhenRequested() throws {
        let result = try Self.runCLI(arguments: ["usage", "--bogus-flag-xyz", "--format", "toon"])

        #expect(result.status != 0)
        #expect(result.stderr.isEmpty)
        let stdout = try #require(String(bytes: result.stdout, encoding: .utf8))
        #expect(stdout.contains("- provider: cli"))
        #expect(stdout.contains("message: Unknown option --bogus-flag-xyz"))
        #expect(!(stdout.hasPrefix("[{")), "TOON error output should not fall back to a JSON array literal")
        #expect(!(stdout.contains("\"provider\"")), "TOON error output should not contain JSON-quoted keys")
    }

    @Test
    func test_usageCommanderParseFailureWithEqualsFormatRendersTOON() throws {
        let result = try Self.runCLI(arguments: ["usage", "--bogus-flag-xyz", "--format=toon"])

        #expect(result.status != 0)
        #expect(result.stderr.isEmpty)
        let stdout = try #require(String(bytes: result.stdout, encoding: .utf8))
        #expect(stdout.contains("Unknown option --bogus-flag-xyz"))
    }

    /// TOON is a `usage`-only contract. Commands whose help promises `text | json` must keep treating
    /// `--format toon` as an unrecognized value -- reporting on stderr as text -- rather than silently
    /// switching to the JSON branch.
    @Test
    func test_nonUsageCommandsDoNotInheritTOONOutput() throws {
        for command in ["cost", "diagnose", "cache"] {
            let result = try Self.runCLI(arguments: [command, "--format", "toon", "--bogus-flag-xyz"])

            #expect(result.status != 0, "\(command) should still fail on an unknown option")
            #expect(result.stdout.isEmpty, "\(command) must not emit a structured payload on stdout")
            let stderr = try #require(String(bytes: result.stderr, encoding: .utf8))
            #expect(stderr.contains("Unknown option --bogus-flag-xyz"), "\(command) should report the parse failure as text on stderr")
        }
    }

    @Test
    func test_dashboardCommandPrintsOneSnapshotAndExits() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-dashboard-command-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var config = CodexBarConfig.makeDefault()
        config.providers = config.providers.map { provider in
            var disabled = provider
            disabled.enabled = false
            return disabled
        }
        let configURL = root.appendingPathComponent("config.json")
        try CodexBarConfigStore(fileURL: configURL).save(config)

        let result = try Self.runCLI(
            arguments: ["dashboard"],
            environment: [CodexBarConfigStore.pathEnvironmentKey: configURL.path])
        #expect(result.status == 0)
        #expect(result.stdout.last == 0x0A)

        let object = try #require(JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        let providers = try #require(object["providers"] as? [[String: Any]])
        #expect(providers.isEmpty)
        let host = try #require(object["host"] as? [String: Any])
        #expect(host["refreshIntervalSeconds"] as? Int == 0)
    }

    @Test
    func test_dashboardOutputWritesSnapshotFileAndKeepsStdoutSilent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-dashboard-output-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var config = CodexBarConfig.makeDefault()
        config.providers = config.providers.map { provider in
            var disabled = provider
            disabled.enabled = false
            return disabled
        }
        let configURL = root.appendingPathComponent("config.json")
        try CodexBarConfigStore(fileURL: configURL).save(config)

        let snapshotURL = root.appendingPathComponent("snapshot.json")
        // Pre-existing content must be atomically replaced, not appended to.
        try Data("stale".utf8).write(to: snapshotURL)

        let result = try Self.runCLI(
            arguments: ["dashboard", "--output", snapshotURL.path],
            environment: [CodexBarConfigStore.pathEnvironmentKey: configURL.path])
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)

        let written = try Data(contentsOf: snapshotURL)
        #expect(written.last == 0x0A)
        let object = try #require(JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)

        let attributes = try FileManager.default.attributesOfItem(atPath: snapshotURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o644)

        // The staged temp file must not survive a successful publish.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.contains("codexbar-dashboard-") }
        #expect(leftovers == [])
    }

    @Test
    func test_dashboardOutputRejectsEmptyPathAsArgsError() throws {
        let result = try Self.runCLI(arguments: ["dashboard", "--output", ""])

        #expect(result.status != 0)
        #expect(result.stdout.isEmpty)
        let stderrText = try #require(String(bytes: result.stderr, encoding: .utf8))
        #expect(stderrText.contains("--output requires a non-empty file path."))
    }

    @Test
    func test_dashboardAtomicWriteFailsWhenDirectoryIsMissing() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-missing-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("snapshot.json")

        let error = try #require(throws: (any Error).self) {
            try CodexBarCLI.writeDashboardSnapshotAtomically(Data("{}".utf8), toPath: missing.path)
        }
        #expect(error.localizedDescription.contains("does not exist"))
    }

    @Test
    func test_dashboardAtomicWriteReplacesExistingFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-atomic-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent("snapshot.json")
        try Data("old".utf8).write(to: target)

        try CodexBarCLI.writeDashboardSnapshotAtomically(Data("new".utf8), toPath: target.path)

        #expect(try Data(contentsOf: target) == Data("new".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o644)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["snapshot.json"])
    }

    @Test
    func test_decodesFormatFromOptionsAndFlags() {
        let jsonOption = ParsedValues(positional: [], options: ["format": ["json"]], flags: [])
        #expect(CodexBarCLI._decodeFormatForTesting(from: jsonOption) == .json)

        let jsonFlag = ParsedValues(positional: [], options: [:], flags: ["json"])
        #expect(CodexBarCLI._decodeFormatForTesting(from: jsonFlag) == .json)

        let textDefault = ParsedValues(positional: [], options: [:], flags: [])
        #expect(CodexBarCLI._decodeFormatForTesting(from: textDefault) == .text)
    }

    @Test
    func test_providerSelectionPrefersOverride() {
        let selection = CodexBarCLI.providerSelection(rawOverride: "codex", enabled: [.claude, .gemini])
        #expect(selection.asList == [.codex])
    }

    @Test
    func test_normalizeVersionExtractsNumeric() {
        #expect(CodexBarCLI.normalizeVersion(raw: "codex 1.2.3 (build 4)") == "1.2.3")
        #expect(CodexBarCLI.normalizeVersion(raw: "  v2.0  ") == "2.0")
    }

    @Test
    func test_makeHeaderIncludesVersionWhenAvailable() {
        let header = CodexBarCLI.makeHeader(provider: .codex, version: "1.2.3", source: "cli")
        #expect(header.contains("Codex"))
        #expect(header.contains("1.2.3"))
        #expect(header.contains("cli"))
    }

    @Test
    func test_cliVersionFallsBackToContainingAppBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-cli-version-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let appURL = root.appendingPathComponent("CodexBar.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let helpersURL = contentsURL.appendingPathComponent("Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpersURL, withIntermediateDirectories: true)

        let infoURL = contentsURL.appendingPathComponent("Info.plist")
        let plist: [String: Any] = ["CFBundleShortVersionString": "9.8.7"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: infoURL)

        let helperURL = helpersURL.appendingPathComponent("CodexBarCLI")
        try Data().write(to: helperURL)

        #expect(CodexBarCLI.containingAppVersion(for: helperURL) == "9.8.7")
    }

    @Test
    func test_containingAppVersionTerminatesOutsideAppBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-cli-version-noapp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let binURL = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        let executableURL = binURL.appendingPathComponent("CodexBarCLI")
        try Data().write(to: executableURL)

        #expect(CodexBarCLI.containingAppVersion(for: executableURL) == nil)
        #expect(CodexBarCLI.containingAppVersion(for: URL(fileURLWithPath: "/")) == nil)
    }

    @Test
    func test_nextAncestorRejectsNonDecreasingParents() {
        let current = URL(fileURLWithPath: "/synthetic/current")
        let candidates = [
            URL(fileURLWithPath: "/distinct/sibling"),
            URL(fileURLWithPath: "/synthetic/current/child"),
        ]

        for candidate in candidates {
            var calls = 0
            let ancestor = CodexBarCLI.nextAncestor(from: current) { _ in
                calls += 1
                return candidate
            }

            #expect(ancestor == nil)
            #expect(calls == 1)
        }
    }

    @Test
    func test_cliVersionFollowsSymlinkedHelper() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-cli-version-symlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let appURL = root.appendingPathComponent("CodexBar.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let helpersURL = contentsURL.appendingPathComponent("Helpers", isDirectory: true)
        let binURL = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: helpersURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)

        let infoURL = contentsURL.appendingPathComponent("Info.plist")
        let plist: [String: Any] = ["CFBundleShortVersionString": "2.4.6"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: infoURL)

        let helperURL = helpersURL.appendingPathComponent("CodexBarCLI")
        try Data().write(to: helperURL)

        let symlinkURL = binURL.appendingPathComponent("codexbar")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: helperURL)

        #expect(CodexBarCLI.currentVersion(bundleVersion: nil, executablePath: symlinkURL.path) == "2.4.6")
    }

    @Test
    func test_cliVersionFallsBackToAdjacentVersionFile() throws {
        try self.expectAdjacentVersionFile(raw: "v3.2.1\n", expected: "3.2.1")
        try self.expectAdjacentVersionFile(raw: "3.2.2\n", expected: "3.2.2")
        try self.expectAdjacentVersionFile(raw: "version-3.2.3\n", expected: "version-3.2.3")
    }

    @Test
    func test_cliVersionFindsAdjacentVersionWhenInvokedViaRelativePathAndSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-cli-version-invocation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let installURL = root.appendingPathComponent("install/bin", isDirectory: true)
        let linksURL = root.appendingPathComponent("links", isDirectory: true)
        let workingDirectoryURL = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: installURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linksURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workingDirectoryURL, withIntermediateDirectories: true)

        let executableURL = installURL.appendingPathComponent("CodexBarCLI")
        try FileManager.default.copyItem(at: Self.cliExecutableURL, to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        try "8.7.6\n".write(
            to: installURL.appendingPathComponent("VERSION"),
            atomically: false,
            encoding: .utf8)

        #expect(try Self.runVersionCommand(
                executableURL: executableURL,
                argv0: "install/bin/CodexBarCLI",
                currentDirectoryURL: workingDirectoryURL) == "CodexBar 8.7.6\n")

        let symlinkURL = linksURL.appendingPathComponent("codexbar")
        try FileManager.default.createSymbolicLink(
            atPath: symlinkURL.path,
            withDestinationPath: "../install/bin/CodexBarCLI")
        #expect(try Self.runVersionCommand(
                executableURL: symlinkURL,
                argv0: "codexbar",
                currentDirectoryURL: workingDirectoryURL) == "CodexBar 8.7.6\n")
    }

    @Test
    func test_cliVersionPrefersAdjacentVersionOverStandaloneBundleName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-cli-version-bundle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let binURL = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)

        let helperURL = binURL.appendingPathComponent("CodexBarCLI")
        try Data().write(to: helperURL)
        try "4.5.6\n".write(
            to: binURL.appendingPathComponent("VERSION"),
            atomically: false,
            encoding: .utf8)

        #expect(CodexBarCLI.currentVersion(bundleVersion: "CodexBar", executablePath: helperURL.path) == "4.5.6")
    }

    private func expectAdjacentVersionFile(raw: String, expected: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-cli-version-file-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let binURL = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)

        let helperURL = binURL.appendingPathComponent("CodexBarCLI")
        try Data().write(to: helperURL)
        try raw.write(
            to: binURL.appendingPathComponent("VERSION"),
            atomically: false,
            encoding: .utf8)

        #expect(CodexBarCLI.currentVersion(bundleVersion: nil, executablePath: helperURL.path) == expected)
    }

    private static func runVersionCommand(
        executableURL: URL,
        argv0: String,
        currentDirectoryURL: URL) throws -> String
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-c",
            "exec -a \"$1\" \"$2\" --version",
            "codexbar-version-test",
            argv0,
            executableURL.path,
        ]
        process.currentDirectoryURL = currentDirectoryURL
        // Spawned CLI binaries match no test-process name pattern; make the
        // keychain suppression explicit instead of relying on env inheritance.
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1"]) { _, new in new }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(bytes: errorOutput, encoding: .utf8)
                ?? "CodexBarCLI exited without an error message"
            throw NSError(domain: "CLIEntryTests", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
        guard let text = String(bytes: output, encoding: .utf8) else {
            throw NSError(domain: "CLIEntryTests", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "CodexBarCLI produced non-UTF-8 output",
            ])
        }
        return text
    }

    private static var cliExecutableURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/CodexBarCLI")
    }

    @Test
    func test_renderOpenAIWebDashboardTextIncludesSummary() {
        let event = CreditEvent(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            service: "codex",
            creditsUsed: 10)
        let snapshot = OpenAIDashboardSnapshot(
            signedInEmail: "user@example.com",
            codeReviewRemainingPercent: 45,
            codeReviewLimit: RateWindow(
                usedPercent: 55,
                windowMinutes: nil,
                resetsAt: Date().addingTimeInterval(3600),
                resetDescription: nil),
            creditEvents: [event],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            updatedAt: Date())

        let text = CodexBarCLI.renderOpenAIWebDashboardText(snapshot)

        #expect(text.contains("Web session: user@example.com"))
        #expect(text.contains("Code review: 45% remaining (Resets in "))
        #expect(text.contains("Web history: 1 events"))
    }

    @Test
    func test_mapsErrorsToExitCodes() {
        #expect(CodexBarCLI.mapError(CodexStatusProbeError.codexNotInstalled) == ExitCode(2))
        #expect(CodexBarCLI.mapError(CodexStatusProbeError.timedOut) == ExitCode(4))
        #expect(CodexBarCLI.mapError(ClaudeWebFetchStrategyError.timedOut(seconds: 1)) == ExitCode(4))
        #expect(CodexBarCLI.mapError(UsageError.noRateLimitsFound) == ExitCode(3))
    }

    @Test
    func test_antigravityPlanDebugKeepsOneShotHelperAliveUntilDebugFetch() {
        #expect(CodexBarCLI.holdsAntigravityCLISessionForPlanDebug(
            provider: .antigravity,
            planDebugEnabled: true,
            jsonOnly: false,
            persistsCLISessions: false))
        #expect(!(CodexBarCLI.holdsAntigravityCLISessionForPlanDebug(
            provider: .codex,
            planDebugEnabled: true,
            jsonOnly: false,
            persistsCLISessions: false)))
        #expect(!(CodexBarCLI.holdsAntigravityCLISessionForPlanDebug(
            provider: .antigravity,
            planDebugEnabled: true,
            jsonOnly: true,
            persistsCLISessions: false)))
        #expect(!(CodexBarCLI.holdsAntigravityCLISessionForPlanDebug(
            provider: .antigravity,
            planDebugEnabled: true,
            jsonOnly: false,
            persistsCLISessions: true)))
    }

    @Test
    func test_missingCodexBinaryErrorPayloadUsesInstallGuidance() {
        let payload = CodexBarCLI.makeErrorPayload(CodexStatusProbeError.codexNotInstalled, kind: .provider)

        #expect(payload.code == ExitCode.binaryNotFound.rawValue)
        #expect(payload.message.contains("Codex CLI missing"))
        #expect(!(payload.message.contains("Codex not running")))
    }

    @Test
    func test_providerSelectionFallsBackToBothForPrimaryPair() {
        let selection = CodexBarCLI.providerSelection(rawOverride: nil, enabled: [.codex, .claude])
        switch selection {
        case .both:
            break
        default:
            Issue.record("Expected both selection")
        }
    }

    @Test
    func test_providerSelectionFallsBackToCustomWhenNonPrimary() {
        let selection = CodexBarCLI.providerSelection(rawOverride: nil, enabled: [.codex, .gemini])
        switch selection {
        case let .custom(providers):
            #expect(providers == [.codex, .gemini])
        default:
            Issue.record("Expected custom selection")
        }
    }

    @Test
    func test_providerSelectionHonorsEmptyEnabledSet() {
        let selection = CodexBarCLI.providerSelection(rawOverride: nil, enabled: [])
        switch selection {
        case let .custom(providers):
            #expect(providers == [])
        default:
            Issue.record("Expected empty custom selection")
        }
    }

    @Test
    func test_decodesSourceAndTimeoutOptions() throws {
        let signature = CodexBarCLI._usageSignatureForTesting()
        let parser = CommandParser(signature: signature)
        let parsed = try parser.parse(arguments: ["--web-timeout", "45", "--source", "oauth"])
        #expect(try CodexBarCLI._decodeWebTimeoutForTesting(from: parsed) == 45)
        #expect(CodexBarCLI._decodeSourceModeForTesting(from: parsed) == .oauth)

        let parsedWeb = try parser.parse(arguments: ["--web"])
        #expect(CodexBarCLI._decodeSourceModeForTesting(from: parsedWeb) == .web)
    }

    @Test
    func test_rejectsUnsafeWebTimeoutOptions() throws {
        for value in ["-1", "nan", "inf", "1e300"] {
            let parsed = ParsedValues(positional: [], options: ["webTimeout": [value]], flags: [])
            #expect(throws: (any Error).self) {
                try CodexBarCLI._decodeWebTimeoutForTesting(from: parsed)
            }
        }
    }

    @Test
    func test_shouldUseColorRespectsFormatAndFlags() {
        #expect(!(CodexBarCLI.shouldUseColor(noColor: true, format: .text)))
        #expect(!(CodexBarCLI.shouldUseColor(noColor: false, format: .json)))
    }

    @Test
    func test_kiloUsageTextNotesShowFallbackOnlyForAutoResolvedToCLI() {
        #expect(CodexBarCLI.usageTextNotes(
            provider: .kilo,
            sourceMode: .auto,
            resolvedSourceLabel: "cli") == ["Using CLI fallback"])
        #expect(CodexBarCLI.usageTextNotes(
            provider: .kilo,
            sourceMode: .api,
            resolvedSourceLabel: "cli").isEmpty)
        #expect(CodexBarCLI.usageTextNotes(
            provider: .codex,
            sourceMode: .auto,
            resolvedSourceLabel: "cli").isEmpty)
    }

    @Test
    func test_kiloAutoFallbackSummaryIncludesOrderedAttemptDetails() {
        let attempts = [
            ProviderFetchAttempt(
                strategyID: "kilo.api",
                kind: .apiToken,
                wasAvailable: true,
                errorDescription: "Kilo authentication failed (401/403)."),
            ProviderFetchAttempt(
                strategyID: "kilo.cli",
                kind: .cli,
                wasAvailable: true,
                errorDescription: "Kilo CLI session not found."),
        ]

        let summary = CodexBarCLI.kiloAutoFallbackSummary(
            provider: .kilo,
            sourceMode: .auto,
            attempts: attempts)
        let expected = [
            "Kilo auto fallback attempts: api: Kilo authentication failed (401/403).",
            " -> cli: Kilo CLI session not found.",
        ].joined()

        #expect(summary == expected)
    }

    @Test
    func test_kiloAutoFallbackSummaryIsNilOutsideKiloAutoFailures() {
        let attempts = [
            ProviderFetchAttempt(
                strategyID: "kilo.api",
                kind: .apiToken,
                wasAvailable: true,
                errorDescription: "example"),
        ]

        #expect(CodexBarCLI.kiloAutoFallbackSummary(
            provider: .kilo,
            sourceMode: .api,
            attempts: attempts) == nil)
        #expect(CodexBarCLI.kiloAutoFallbackSummary(
            provider: .codex,
            sourceMode: .auto,
            attempts: attempts) == nil)
    }

    @Test
    func test_sourceModeRequiresWebSupportIsProviderAware() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimo-cli-source-mode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let validMiMoCache = directory.appendingPathComponent("valid.json")
        let invalidMiMoCache = directory.appendingPathComponent("invalid.json")
        let payload: [String: Any] = [
            "sessions_scanned": 1,
            "windows": [
                "today": [:],
                "week": [:],
                "all_time": [:],
            ],
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: validMiMoCache)
        try Data("{}".utf8).write(to: invalidMiMoCache)

        #expect(CodexBarCLI.sourceModeRequiresWebSupport(.web, provider: .kilo))
        #expect(!(CodexBarCLI.sourceModeRequiresWebSupport(.auto, provider: .codex)))
        #expect(!(CodexBarCLI.sourceModeRequiresWebSupport(.auto, provider: .claude)))
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(.web, provider: .claude))
        #expect(!(CodexBarCLI.sourceModeRequiresWebSupport(.auto, provider: .kilo)))
        #expect(!(CodexBarCLI.sourceModeRequiresWebSupport(.auto, provider: .grok)))
        #expect(!(CodexBarCLI.sourceModeRequiresWebSupport(.web, provider: .grok)))
        #expect(!(CodexBarCLI.sourceModeRequiresWebSupport(.auto, provider: .amp)))
        #expect(!(CodexBarCLI.sourceModeRequiresWebSupport(.api, provider: .kilo)))
        #expect(!(CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .opencodego,
            settings: ProviderSettingsSnapshot.make(
                opencodego: .init(
                    cookieSource: .manual,
                    manualCookieHeader: "auth=manual",
                    workspaceID: nil)))))
        #expect(!(CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .opencodego,
            settings: ProviderSettingsSnapshot.make(
                opencodego: .init(
                    cookieSource: .manual,
                    manualCookieHeader: "auth=manual",
                    workspaceID: nil)))))
        #expect(!(CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .opencodego,
            settings: ProviderSettingsSnapshot.make(
                opencodego: .init(
                    cookieSource: .auto,
                    manualCookieHeader: nil,
                    workspaceID: nil)))))
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .opencodego,
            settings: ProviderSettingsSnapshot.make(
                opencodego: .init(
                    cookieSource: .auto,
                    manualCookieHeader: nil,
                    workspaceID: nil))))
        #expect(!(CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .commandcode,
            settings: ProviderSettingsSnapshot.make(
                commandcode: .init(
                    cookieSource: .manual,
                    manualCookieHeader: "session=manual")))))
        #expect(!(CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .commandcode,
            settings: ProviderSettingsSnapshot.make(
                commandcode: .init(
                    cookieSource: .manual,
                    manualCookieHeader: "session=manual")))))
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .commandcode,
            settings: ProviderSettingsSnapshot.make(
                commandcode: .init(
                    cookieSource: .auto,
                    manualCookieHeader: nil))))
        #expect(!(CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .sakana,
            environment: ["SAKANA_COOKIE": "session=manual"])))
        #expect(!(CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .sakana,
            environment: ["SAKANA_COOKIE": "session=manual"])))
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .sakana,
            environment: [:]))
        #expect(!(CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .qoder,
            settings: ProviderSettingsSnapshot.make(
                qoder: .init(
                    cookieSource: .manual,
                    manualCookieHeader: "sid=manual")))))
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .qoder,
            settings: ProviderSettingsSnapshot.make(
                qoder: .init(
                    cookieSource: .auto,
                    manualCookieHeader: nil))))
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .opencode,
            settings: ProviderSettingsSnapshot.make(
                opencode: .init(
                    cookieSource: .manual,
                    manualCookieHeader: "auth=manual",
                    workspaceID: nil))))
        #expect(!(CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .ollama,
            environment: ["OLLAMA_API_KEY": "ollama-test"])))
        #expect(!(CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .codex,
            environment: ["OLLAMA_API_KEY": "ollama-test"])))
        #expect(!(CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .ollama,
            settings: ProviderSettingsSnapshot.make(
                ollama: .init(cookieSource: .off, manualCookieHeader: nil)))))
        #expect(!(CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .kimi,
            environment: ["KIMI_CODE_API_KEY": "kimi-test"])))
        try self.assertKimiCodeCredentialSourceMode(in: directory)
        #expect(!(CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .mimo,
            environment: ["MIMO_LOCAL_USAGE_PATH": validMiMoCache.path])))
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .mimo,
            environment: ["MIMO_LOCAL_USAGE_PATH": validMiMoCache.path]))
        #expect(!(CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .mimo,
            environment: ["MIMO_LOCAL_USAGE_PATH": invalidMiMoCache.path])))
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .mimo,
            environment: ["MIMO_LOCAL_USAGE_PATH": directory.appendingPathComponent("missing.json").path]))
    }

    @Test
    func test_sourceModeRequiresWebSupportAllowsOllamaManualCookieOnLinuxGate() {
        #expect(!(CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .ollama,
            settings: ProviderSettingsSnapshot.make(
                ollama: .init(cookieSource: .manual, manualCookieHeader: "__Secure-session=manual")))))
        #expect(!(CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .ollama,
            settings: ProviderSettingsSnapshot.make(
                ollama: .init(cookieSource: .manual, manualCookieHeader: "__Secure-session=manual")))))
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .ollama,
            settings: ProviderSettingsSnapshot.make(
                ollama: .init(cookieSource: .manual, manualCookieHeader: "   "))))
    }

    @Test
    func test_sourceModeRequiresWebSupportAllowsQwenCookiesOnLinuxGate() {
        #expect(!(CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .qwencloud,
            environment: ["QWEN_CLOUD_COOKIE": "login_qwencloud_ticket=test"])))
        #expect(!(CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .qwencloud,
            settings: ProviderSettingsSnapshot.make(
                qwenCloud: .init(
                    cookieSource: .manual,
                    manualCookieHeader: "login_qwencloud_ticket=test")))))
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .qwencloud,
            environment: [:]))
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .qwencloud,
            environment: ["QWEN_CLOUD_COOKIE": "login_qwencloud_ticket=test"],
            settings: ProviderSettingsSnapshot.make(
                qwenCloud: .init(cookieSource: .off, manualCookieHeader: nil))))
    }

    private func assertKimiCodeCredentialSourceMode(in directory: URL) throws {
        let home = directory.appendingPathComponent("kimi-code", isDirectory: true)
        let credentials = home.appendingPathComponent("credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "access_token": "expired",
            "refresh_token": "refresh",
            "expires_at": Date().addingTimeInterval(-60).timeIntervalSince1970,
        ]
        try JSONSerialization.data(withJSONObject: payload)
            .write(to: credentials.appendingPathComponent("kimi-code.json"))

        #expect(!(CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .kimi,
            environment: ["KIMI_CODE_HOME": home.path])))
    }

    @Test
    func test_sourceModeRequiresWebSupportAllowsFactoryAPIKeyOnLinuxGate() {
        #expect(!(CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .factory,
            environment: ["FACTORY_API_KEY": "fk-test"])))
        #expect(!(CodexBarCLI.sourceModeRequiresWebSupport(
            .cli,
            provider: .factory,
            environment: ["FACTORY_API_KEY": "fk-test"])))
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .factory,
            environment: [:]))
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .factory,
            environment: ["FACTORY_API_KEY": "fk-test"]))
        #expect(!(CodexBarCLI.sourceModeRequiresWebSupport(
            .api,
            provider: .factory,
            environment: [:])))
    }

    private static func runCLI(
        arguments: [String],
        environment: [String: String] = [:]) throws -> (status: Int32, stdout: Data, stderr: Data)

    {
        let process = Process()
        process.executableURL = Self.cliExecutableURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            stdout.fileHandleForReading.readDataToEndOfFile(),
            stderr.fileHandleForReading.readDataToEndOfFile())
    }
}
