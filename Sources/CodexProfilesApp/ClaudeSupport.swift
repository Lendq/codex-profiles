import Foundation

enum ClaudeSupport {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func projectSlug(_ url: URL) -> String {
        let units = Array(url.resolvingSymlinksInPath().path.utf16)
        let slug = String(units.map { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) ? Character(UnicodeScalar($0)!) : "-" })
        guard slug.count > 200 else { return slug }
        let hash = units.reduce(Int32(0)) { $0 &* 31 &+ Int32($1) }
        return String(slug.prefix(200)) + "-" + String(abs(Int64(hash)), radix: 36)
    }

    static func servers(from data: Data, project: URL) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Claude", code: 1, userInfo: [NSLocalizedDescriptionKey: "Claude settings are not a JSON object."])
        }
        var servers = json["mcpServers"] as? [String: Any] ?? [:]
        let projects = json["projects"] as? [String: Any] ?? [:]
        let entry = (projects[project.path] ?? projects[project.resolvingSymlinksInPath().path]) as? [String: Any]
        for (key, value) in entry?["mcpServers"] as? [String: Any] ?? [:] { servers[key] = value }
        return servers
    }

    static func command(executable: String, project: String, configDirectory: String?, mcpConfig: String?, resumeFile: String?) -> String {
        var result = "cd " + quote(project) + " && env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CONFIG_DIR "
        if let configDirectory { result += "CLAUDE_CONFIG_DIR=" + quote(configDirectory) + " " }
        result += quote(executable)
        if let mcpConfig { result += " --mcp-config " + quote(mcpConfig) }
        if let resumeFile { result += " --resume " + quote(resumeFile) + " --fork-session" }
        return result
    }

    struct Session {
        let url: URL
        let modified: Date
        let account: String
    }

    static func sessions(roots: [(String, URL)], project: URL, fileManager: FileManager = .default) -> [Session] {
        let slug = projectSlug(project)
        var result: [Session] = []
        for (name, root) in roots {
            let folder = root.appendingPathComponent("projects").appendingPathComponent(slug)
            let files = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
                if values?.isRegularFile == true && (values?.fileSize ?? 0) > 0 {
                    result.append(Session(url: file, modified: values?.contentModificationDate ?? .distantPast, account: name))
                }
            }
        }
        return result.sorted { $0.modified > $1.modified }
    }

    struct UsageReading {
        let id: String
        let used: Double
        let minutes: Int
        let resets: Date?
    }

    static func parseUsage(_ data: Data) throws -> [UsageReading] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "ClaudeUsage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Claude returned an unexpected usage response."])
        }
        let formatter = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [("five_hour", 300), ("seven_day", 10080)].compactMap { key, duration in
            guard let item = json[key] as? [String: Any], let used = item["utilization"] as? NSNumber, used.doubleValue.isFinite else { return nil }
            let raw = item["resets_at"] as? String
            let date = raw.flatMap { fractional.date(from: $0) ?? formatter.date(from: $0) }
            return UsageReading(id: key, used: max(0, min(100, used.doubleValue)), minutes: duration, resets: date)
        }
    }

}
