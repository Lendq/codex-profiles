import Foundation
func testClaudeBackup() throws {
    let c = Data("{\"claudeAiOauth\":{\"accessToken\":\"abc\",\"refreshToken\":\"def\"},\"mcpOAuth\":{\"secret\":\"omit\"}}".utf8)
    let i = Data("{\"oauthAccount\":{\"emailAddress\":\"test@example.test\"},\"userID\":\"id\",\"other\":\"omit\"}".utf8)
    let data = try ClaudeBackup.encode(credential: c, identity: i, name: "Work", symbol: "bolt", tint: "blue")
    let decoded = try ClaudeBackup.decode(data)
    check(decoded.email == "test@example.test" && decoded.name == "Work", "backup round trip")
    check(!String(decoding: data, as: UTF8.self).contains("mcpOAuth") && !String(decoding: data, as: UTF8.self).contains("omit"), "backup excludes unrelated data")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("backup.json"); try ClaudeBackup.writePrivate(data, to: file)
    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    check(permissions == 0o600, "backup is private")
    do { _ = try ClaudeBackup.decode(Data("{}".utf8)); fatalError("invalid backup accepted") } catch {}
    let raw = Data("{\"claudeAiOauth\":{\"accessToken\":\"live\"}}".utf8)
    let hex = Data(raw.map { String(format: "%02x", $0) }.joined().utf8)
    check(ClaudeUsageClient.token(from: raw) == "live" && ClaudeUsageClient.token(from: hex) == "live", "JSON and Keychain hex tokens")
    let expired = Data("{\"claudeAiOauth\":{\"accessToken\":\"expired\",\"expiresAt\":1}}".utf8)
    check(ClaudeUsageClient.token(from: expired) == nil, "expired token is not sent")
    print("PASS: Claude backups validate and exclude MCP credentials")
}
