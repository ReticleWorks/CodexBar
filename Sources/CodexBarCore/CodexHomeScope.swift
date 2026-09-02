import Foundation

public enum CodexHomeScope {
    public static func normalizedHomePath(
        _ rawPath: String?,
        fileManager: FileManager = .default)
        -> String?
    {
        guard var path = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        if path == "~" {
            path = fileManager.homeDirectoryForCurrentUser.path
        } else if path.hasPrefix("~/") {
            path = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2)), isDirectory: true)
                .path
        } else if path.hasPrefix("~") {
            return nil
        }
        guard (path as NSString).isAbsolutePath else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    public static func ambientHomeURL(
        env: [String: String],
        fileManager: FileManager = .default)
        -> URL
    {
        if let raw = env["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        // Provider-specific by design: `.codex` is the CLI's default on-disk home contract.
        return fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    public static func scopedEnvironment(base: [String: String], codexHome: String?) -> [String: String] {
        guard let codexHome, !codexHome.isEmpty else { return base }
        var env = base
        env["CODEX_HOME"] = codexHome
        return env
    }

    /// Normalizes and dedupes `configured`, then appends any direct child of the home
    /// directory named `.codex` or `.codex-*` that holds an `auth.json` and isn't already
    /// configured. Discovery is non-recursive (home directory only). Configured paths keep
    /// their original order; discovered paths are appended sorted.
    public static func discoveredHomePaths(
        configured: [String]?,
        fileManager: FileManager = .default)
        -> [String]
    {
        var seen: Set<String> = []
        var result: [String] = []
        for path in (configured ?? []).compactMap({ normalizedHomePath($0, fileManager: fileManager) }) {
            guard seen.insert(path).inserted else { continue }
            result.append(path)
        }

        let home = fileManager.homeDirectoryForCurrentUser
        let childNames = (try? fileManager.contentsOfDirectory(atPath: home.path)) ?? []
        var discovered: [String] = []
        for name in childNames {
            guard name == ".codex" || name.hasPrefix(".codex-") else { continue }
            let candidate = home.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  fileManager.fileExists(atPath: candidate.appendingPathComponent("auth.json").path),
                  let normalized = normalizedHomePath(candidate.path, fileManager: fileManager),
                  seen.insert(normalized).inserted
            else { continue }
            discovered.append(normalized)
        }
        return result + discovered.sorted()
    }
}
