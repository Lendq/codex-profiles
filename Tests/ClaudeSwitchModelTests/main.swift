import AppKit
import Foundation

struct ProfileRow: Identifiable {
    let id: String; let profileID: UUID?; let title: String; let email: String?
    let avatarSymbol: String?; let avatarColorToken: String?; let createdAt: Date?; let lastLoadedAt: Date?
    let isCurrent: Bool; let isUnsavedCurrent: Bool
    var plan: String? = nil; var renewalWarning: String? = nil; var usage: UsageSnapshot? = nil
    var isSwitching = false; var shortcutNumber: Int? = nil
}
enum SortOrder { case recent, created, name }
func check(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) } }
@MainActor func runTests() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("claude-model-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let fakeBin = root.appendingPathComponent("bin")
    try fm.createDirectory(at: fakeBin, withIntermediateDirectories: true)
    let pgrep = fakeBin.appendingPathComponent("pgrep")
    try Data("#!/bin/sh\nexit 1\n".utf8).write(to: pgrep)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: pgrep.path)
    let suite = "claude-test-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let oldID = UUID()
    let legacyData = try JSONSerialization.data(withJSONObject: [["id":oldID.uuidString,"name":"old label","isDefault":false]])
    defaults.set(legacyData, forKey: "claude_profiles_v1")
    let source = root.appendingPathComponent(".local/share/codex-profiles/claude").appendingPathComponent(oldID.uuidString)
    try fm.createDirectory(at: root.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    let now = Date().timeIntervalSince1970 * 1000
    func identity(_ email: String) throws -> Data { try JSONSerialization.data(withJSONObject: ["oauthAccount":["emailAddress":email],"userID":email,"mcpServers":["shared":["command":"test"]]]) }
    func creds(_ token: String, offset: Double) throws -> Data { try JSONSerialization.data(withJSONObject: ["claudeAiOauth":["accessToken":token,"refreshToken":"r-"+token,"expiresAt":now+3600000,"refreshTokenExpiresAt":now+offset,"subscriptionType":"pro"],"mcpOAuth":["server":["accessToken":"mcp"]]]) }
    try identity("first@example.test").write(to: root.appendingPathComponent(".claude.json"))
    try identity("second@example.test").write(to: source.appendingPathComponent(".claude.json"))
    try creds("first", offset: 2400000000).write(to: root.appendingPathComponent(".claude/.credentials.json"))
    try creds("second", offset: 2500000000).write(to: source.appendingPathComponent(".credentials.json"))
    let helper = URL(fileURLWithPath: CommandLine.arguments[1])
    let model = ClaudeSwitchModel(home: root, helper: helper, defaults: defaults, environmentOverrides: ["CCSWITCH_BACKEND":"file", "PATH":fakeBin.path+":/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"])
    model.reload()
    check(model.rows.count == 2 && model.rows[0].title == "first@example.test" && model.rows[0].isUnsavedCurrent, "current account uses email")
    check(model.rows[1].title == "second@example.test", "old account uses email")
    model.switchTo(oldID)
    check(model.errorMessage == nil, "migration and switch succeed")
    check(model.rows.count == 2 && model.rows.contains { $0.profileID == oldID && $0.isCurrent && $0.plan == "Pro" }, "migrated account is current with plan")
    let current = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(".claude/.credentials.json"))) as! [String: Any]
    check((current["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String == "second", "selected credential is active")
    check(((current["mcpOAuth"] as? [String: Any])?["server"] as? [String: String])?["accessToken"] == "mcp", "MCP authorization is shared")
    let firstID = model.rows.first { $0.email == "first@example.test" }!.profileID!
    model.switchTo(firstID)
    check(model.errorMessage == nil && model.rows.contains { $0.profileID == firstID && $0.isCurrent }, "switch back preserves first account")
    model.update(firstID, name: "Work", symbol: "briefcase", tint: "red")
    check(model.rows.contains { $0.profileID == firstID && $0.title == "Work" && $0.avatarColorToken == "red" }, "profile editor")
    let sorted = model.orderedRows(.name)
    check(sorted.count == 2 && sorted.allSatisfy { $0.shortcutNumber != nil }, "profile shortcuts")
    model.signOutLocally()
    check(model.errorMessage == nil && !model.rows.contains(where: { $0.isCurrent }), "sign out preserves saved accounts")
    check(!fm.fileExists(atPath: root.appendingPathComponent(".claude/.credentials.json").path), "sign out clears live login")
    model.switchTo(oldID)
    check(model.errorMessage == nil && model.rows.contains { $0.profileID == oldID && $0.isCurrent }, "saved login can be restored after sign out")
    print("PASS: Claude account model, migration, switching and appearance")
}
try testClaudeBackup()
try MainActor.assumeIsolated { try runTests() }
