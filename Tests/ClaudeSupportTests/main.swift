import Foundation

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}
let project = URL(fileURLWithPath: "/tmp/a b")
check(ClaudeSupport.projectSlug(project) == "-tmp-a-b" || ClaudeSupport.projectSlug(project) == "-private-tmp-a-b", "project slug")
check(ClaudeSupport.quote("a'b $x") == "'a'\\''b $x'", "shell quoting")
let data = Data("""
{"mcpServers":{"shared":{"command":"one"},"same":{"command":"global"}},"projects":{"/tmp/a b":{"mcpServers":{"same":{"command":"project"},"local":{"command":"two"}}}},"oauthAccount":{"emailAddress":"private"}}
""".utf8)
let servers = try ClaudeSupport.servers(from: data, project: project)
check(servers.count == 3, "servers merged")
check((servers["same"] as? [String: String])?["command"] == "project", "project server takes precedence")
check(servers["oauthAccount"] == nil, "identity excluded")
print("Claude support checks passed")
let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let root1 = temp.appendingPathComponent("first")
let root2 = temp.appendingPathComponent("second")
for root in [root1, root2] {
    try FileManager.default.createDirectory(at: root.appendingPathComponent("projects").appendingPathComponent(ClaudeSupport.projectSlug(project)), withIntermediateDirectories: true)
}
let folder = root1.appendingPathComponent("projects").appendingPathComponent(ClaudeSupport.projectSlug(project))
try Data("hello".utf8).write(to: folder.appendingPathComponent("session.jsonl"))
try Data().write(to: folder.appendingPathComponent("empty.jsonl"))
try Data("hello".utf8).write(to: folder.appendingPathComponent("other.txt"))
let found = ClaudeSupport.sessions(roots: [("first", root1), ("second", root2)], project: project)
check(found.count == 1 && found[0].account == "first", "session discovery excludes empty and non-session files")
let executable = temp.appendingPathComponent("fake claude")
let output = temp.appendingPathComponent("result")
let fake = "#!/bin/sh\nprintf '%s\\n' \"$CLAUDE_CONFIG_DIR\" \"${ANTHROPIC_API_KEY-unset}\" \"$@\" > " + ClaudeSupport.quote(output.path) + "\n"
try Data(fake.utf8).write(to: executable)
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
let command = ClaudeSupport.command(executable: executable.path, project: temp.path, configDirectory: "/tmp/profile's dir", mcpConfig: "/tmp/mcp config", resumeFile: "/tmp/session's file.jsonl")
let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", command]
process.environment = ["PATH": "/usr/bin:/bin", "ANTHROPIC_API_KEY": "test-secret"]
try process.run(); process.waitUntilExit()
check(process.terminationStatus == 0, "launch command runs")
let lines = try String(contentsOf: output, encoding: .utf8).split(separator: "\n").map(String.init)
check(lines == ["/tmp/profile's dir", "unset", "--mcp-config", "/tmp/mcp config", "--resume", "/tmp/session's file.jsonl", "--fork-session"], "handoff arguments and environment")
print("Claude handoff checks passed")
let usageJSON = Data("""
{"five_hour":{"utilization":72,"resets_at":"2026-10-18T18:10:00.299994+00:00"},"seven_day":{"utilization":41,"resets_at":"2026-10-22T03:00:00Z"}}
""".utf8)
let usage = try ClaudeSupport.parseUsage(usageJSON)
check(usage.count == 2 && usage[0].used == 72 && usage[1].minutes == 10080, "Claude quota windows")
check(usage.allSatisfy { $0.resets != nil }, "Claude reset times")
let missingUsage = try ClaudeSupport.parseUsage(Data("{\"five_hour\":null}".utf8))
check(missingUsage.isEmpty, "missing quota")
