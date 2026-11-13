import Foundation
import Darwin

enum ClaudeBackup {
    struct Decoded {
        let credential: Data
        let identity: Data
        let email: String
        let name: String?
        let symbol: String?
        let tint: String?
    }
    static func encode(credential: Data, identity: Data, name: String?, symbol: String?, tint: String?) throws -> Data {
        guard let credentials = try JSONSerialization.jsonObject(with: credential) as? [String: Any],
              let oauth = credentials["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String, !access.isEmpty,
              let refresh = oauth["refreshToken"] as? String, !refresh.isEmpty,
              let info = try JSONSerialization.jsonObject(with: identity) as? [String: Any],
              let account = info["oauthAccount"] as? [String: Any],
              let email = account["emailAddress"] as? String, !email.isEmpty else { throw error("This Claude profile has no usable saved login.") }
        var cleanIdentity: [String: Any] = ["oauthAccount": account]
        if let userID = info["userID"] { cleanIdentity["userID"] = userID }
        var appearance: [String: String] = [:]
        if let name { appearance["name"] = name }; if let symbol { appearance["symbol"] = symbol }; if let tint { appearance["tint"] = tint }
        return try JSONSerialization.data(withJSONObject: ["format": "codex-profiles-claude", "version": 1, "identity": cleanIdentity, "credentials": ["claudeAiOauth": oauth], "appearance": appearance], options: [.prettyPrinted, .sortedKeys])
    }
    static func decode(_ data: Data) throws -> Decoded {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], json["format"] as? String == "codex-profiles-claude", (json["version"] as? Int) == 1,
              let identity = json["identity"] as? [String: Any], let credential = json["credentials"] as? [String: Any] else { throw error("This is not a supported Claude profile backup.") }
        let checked = try encode(credential: JSONSerialization.data(withJSONObject: credential), identity: JSONSerialization.data(withJSONObject: identity), name: nil, symbol: nil, tint: nil)
        let clean = try JSONSerialization.jsonObject(with: checked) as! [String: Any]
        let cleanIdentity = clean["identity"] as! [String: Any], cleanCredential = clean["credentials"] as! [String: Any]
        let email = (cleanIdentity["oauthAccount"] as! [String: Any])["emailAddress"] as! String
        let appearance = json["appearance"] as? [String: String] ?? [:]
        return Decoded(credential: try JSONSerialization.data(withJSONObject: cleanCredential), identity: try JSONSerialization.data(withJSONObject: cleanIdentity), email: email, name: appearance["name"], symbol: appearance["symbol"], tint: appearance["tint"])
    }
    static func writePrivate(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".claude-profile-" + UUID().uuidString)
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw error("Could not create the backup file.") }
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try file.write(contentsOf: data); try file.synchronize(); try file.close()
        guard rename(temp.path, url.path) == 0 else { throw error("Could not save the backup file.") }
    }
    private static func error(_ message: String) -> NSError { NSError(domain: "ClaudeBackup", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
