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
struct BrowserLoginState { var message: String; var authorizationURL: URL? }
func check(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) } }
@MainActor func runTests() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("claude-model-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let fakeBin = root.appendingPathComponent("bin")
    try fm.createDirectory(at: fakeBin, withIntermediateDirectories: true)
    let pgrep = fakeBin.appendingPathComponent("pgrep")
    try Data("#!/bin/sh\nif [ -n \"${FAKE_RUNNING_PID:-}\" ]; then printf \"%s\\n\" \"$FAKE_RUNNING_PID\"; exit 0; fi\nexit 1\n".utf8).write(to: pgrep)
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
    let liveProcess = Process(); liveProcess.executableURL = URL(fileURLWithPath: "/bin/sleep"); liveProcess.arguments = ["30"]
    try liveProcess.run(); defer { if liveProcess.isRunning { liveProcess.terminate(); liveProcess.waitUntilExit() } }
    let model = ClaudeSwitchModel(home: root, helper: helper, defaults: defaults, environmentOverrides: ["CCSWITCH_BACKEND":"file", "PATH":fakeBin.path+":/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "FAKE_RUNNING_PID":String(liveProcess.processIdentifier)])
    model.reload()
    check(model.rows.count == 2 && model.rows[0].title == "first@example.test" && model.rows[0].isUnsavedCurrent, "current account uses email")
    check(model.rows[1].title == "second@example.test", "old account uses email")
    let beforeSnapshot = try Data(contentsOf: root.appendingPathComponent(".claude/.credentials.json"))
    model.saveCurrent()
    let afterSnapshot = try Data(contentsOf: root.appendingPathComponent(".claude/.credentials.json"))
    check(model.errorMessage == nil && model.rows.contains { $0.isCurrent && !$0.isUnsavedCurrent }, "save current works while a session runs")
    check(beforeSnapshot == afterSnapshot, "saving current does not change the live login")
    // An isolated browser login never needs the live-switch helper or its guard.
    let fakeClaude = fakeBin.appendingPathComponent("fake-claude")
    let fakeScript = """
    #!/bin/sh
    [ "$1" = auth ] && [ "$2" = login ] || exit 7
    [ -z "${ANTHROPIC_API_KEY:-}" ] || exit 8
    [ -z "${CLAUDE_CODE_OAUTH_REFRESH_TOKEN:-}" ] || exit 10
    [ -n "${CLAUDE_CONFIG_DIR:-}" ] || exit 9
    printf '%s' '{"oauthAccount":{"emailAddress":"third@example.test"}}' > "$CLAUDE_CONFIG_DIR/.claude.json"
    printf '%s\\n' 'https://claude.ai/oauth/authorize?test=1'
    sleep 1
    exit 0
    """
    try Data(fakeScript.utf8).write(to: fakeClaude)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeClaude.path)
    let globalBefore = try Data(contentsOf: root.appendingPathComponent(".claude.json"))
    let credentialBefore = try Data(contentsOf: root.appendingPathComponent(".claude/.credentials.json"))
    setenv("ANTHROPIC_API_KEY", "do-not-inherit", 1)
    setenv("CLAUDE_CODE_OAUTH_REFRESH_TOKEN", "do-not-inherit", 1)
    let loginModel = ClaudeSwitchModel(home: root, helper: helper, claude: fakeClaude, defaults: defaults, environmentOverrides: ["CCSWITCH_BACKEND":"file", "PATH":fakeBin.path+":/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"])
    loginModel.reload(); loginModel.login()
    check(loginModel.browserLogin != nil, "browser login is shown")
    let urlDeadline = Date().addingTimeInterval(4)
    while loginModel.browserLogin?.authorizationURL == nil && loginModel.browserLogin != nil && Date() < urlDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    check(loginModel.browserLogin?.authorizationURL?.host == "claude.ai", "browser login exposes the Anthropic authorization URL")
    let deadline = Date().addingTimeInterval(8)
    while loginModel.browserLogin != nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    unsetenv("ANTHROPIC_API_KEY"); unsetenv("CLAUDE_CODE_OAUTH_REFRESH_TOKEN")
    check(loginModel.browserLogin == nil && loginModel.errorMessage == nil, "isolated browser login completed")
    check(loginModel.rows.contains { $0.email == "third@example.test" }, "new account is listed")
    let globalAfter = try Data(contentsOf: root.appendingPathComponent(".claude.json"))
    let credentialAfter = try Data(contentsOf: root.appendingPathComponent(".claude/.credentials.json"))
    check(globalBefore == globalAfter && credentialBefore == credentialAfter, "sign-in leaves the active account untouched")
    liveProcess.terminate(); liveProcess.waitUntilExit()
    let failingClaude = fakeBin.appendingPathComponent("failing-claude")
    try Data("#!/bin/sh\nexit 1\n".utf8).write(to: failingClaude)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: failingClaude.path)
    let failingModel = ClaudeSwitchModel(home: root, helper: helper, claude: failingClaude, defaults: defaults, environmentOverrides: ["CCSWITCH_BACKEND":"file", "PATH":fakeBin.path+":/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"])
    failingModel.reload(); let rowsBeforeFailure = failingModel.rows.count; failingModel.login()
    let failureDeadline = Date().addingTimeInterval(8)
    while failingModel.browserLogin != nil && Date() < failureDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    check(failingModel.errorMessage != nil && failingModel.rows.count == rowsBeforeFailure, "failed sign-in adds no profile")
    let credentialAfterFailure = try Data(contentsOf: root.appendingPathComponent(".claude/.credentials.json"))
    check(credentialAfterFailure == credentialBefore, "failed sign-in keeps the live account")
    // Remove this synthetic login so the remaining migration assertions stay focused.
    if let addedID = loginModel.rows.first(where: { $0.email == "third@example.test" })?.profileID { loginModel.delete(addedID) }
    model.reload()
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
