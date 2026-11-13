import Foundation

private final class AnthropicRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https", request.url?.host == "api.anthropic.com" else { completionHandler(nil); return }
        completionHandler(request)
    }
}

enum ClaudeUsageClient {
    static func token(from data: Data) -> String? {
        var payload = data
        if (try? JSONSerialization.jsonObject(with: payload)) == nil,
           let hex = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           hex.count.isMultiple(of: 2), !hex.isEmpty, hex.allSatisfy({ $0.isHexDigit }) {
            var decoded = Data(); var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
                decoded.append(byte); index = next
            }
            payload = decoded
        }
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        if let expiry = oauth["expiresAt"] as? NSNumber, expiry.doubleValue / 1000 <= Date().timeIntervalSince1970 { return nil }
        return token
    }

    static func activeCredential() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        let name = NSUserName()
        let valid = !name.isEmpty && name.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57) || "._-".unicodeScalars.contains(scalar)
        }
        process.arguments = ["find-generic-password", "-a", valid ? name : "claude-code-user", "-s", "Claude Code-credentials", "-w"]
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do {
            try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch { return nil }
    }

    static func fetch(token: String) async throws -> UsageSnapshot {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 15
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("CodexProfiles", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral, delegate: AnthropicRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "ClaudeUsage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Claude usage is unavailable; sign in again or try later."])
        }
        let windows = try ClaudeSupport.parseUsage(data).map {
            UsageWindow(id: "claude:" + $0.id, bucket: "Claude", usedPercent: $0.used, durationMinutes: $0.minutes, resetsAt: $0.resets)
        }
        guard !windows.isEmpty else { throw NSError(domain: "ClaudeUsage", code: 2, userInfo: [NSLocalizedDescriptionKey: "Claude returned no usage limits."]) }
        return UsageSnapshot(fetchedAt: Date(), windows: windows)
    }
}
