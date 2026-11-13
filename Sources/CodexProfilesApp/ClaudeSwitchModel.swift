import AppKit
import Foundation
import UniformTypeIdentifiers

private struct ClaudeLegacyProfile: Codable {
    let id: UUID
    let name: String
    let isDefault: Bool
}

private struct ClaudeAppearance: Codable {
    var name: String?
    var symbol: String?
    var tint: String?
    var lastLoadedAt: Date? = nil
}

@MainActor
final class ClaudeSwitchModel: ObservableObject {
    @Published var rows: [ProfileRow] = []
    @Published var errorMessage: String?
    @Published var busy = false
    @Published var loadingUsage = false
    @Published var browserLogin: BrowserLoginState?
    private var loginProcess: Process?
    private var loginInput: Pipe?
    private var loginOutput: Pipe?
    private var loginBuffer = Data()
    private var cancelledLogin = false
    private var usage: [String: UsageSnapshot] = [:]
    private var usageAttempts: [String: Date] = [:]
    private var appearances: [String: ClaudeAppearance] = [:]
    private let defaults: UserDefaults
    private let fm = FileManager.default
    private let homeOverride: URL?
    private let helperOverride: URL?
    private let claudeOverride: URL?
    private let environmentOverrides: [String: String]
    init(home: URL? = nil, helper: URL? = nil, claude: URL? = nil, defaults: UserDefaults = .standard, environmentOverrides: [String: String] = [:]) {
        self.homeOverride = home; self.helperOverride = helper; self.claudeOverride = claude; self.defaults = defaults; self.environmentOverrides = environmentOverrides
    }
    private var home: URL { homeOverride ?? fm.homeDirectoryForCurrentUser }
    private var vault: URL { home.appendingPathComponent(".config/codex-profiles-claude", isDirectory: true) }
    private var accounts: URL { vault.appendingPathComponent("accounts", isDirectory: true) }
    private var helper: URL? { helperOverride ?? Bundle.main.resourceURL?.appendingPathComponent("ccswitch") }
    private var legacy: [ClaudeLegacyProfile] {
        guard let data = defaults.data(forKey: "claude_profiles_v1"),
              let saved = try? JSONDecoder().decode([ClaudeLegacyProfile].self, from: data) else { return [] }
        return saved.filter { !$0.isDefault }
    }
    private var currentEmail: String? { identityEmail(home.appendingPathComponent(".claude.json")) }
    private var activeName: String? {
        (try? String(contentsOf: vault.appendingPathComponent("active"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func identityEmail(_ path: URL) -> String? {
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any],
              let email = account["emailAddress"] as? String, !email.isEmpty else { return nil }
        return email
    }
    private func savedPlan(_ directory: URL) -> String? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("credentials.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let raw = oauth["subscriptionType"] as? String else { return nil }
        switch raw.lowercased() {
        case "free": return "Free"
        case "pro": return "Pro"
        case "max": return "Max"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        default: return nil
        }
    }
    func reload() {
        if usage.isEmpty, let data = defaults.data(forKey: "claude_usage_cache_v2"),
           let cached = try? JSONDecoder().decode([String: UsageSnapshot].self, from: data) { usage = cached }
        if let data = defaults.data(forKey: "claude_profile_appearances_v2"),
           let saved = try? JSONDecoder().decode([String: ClaudeAppearance].self, from: data) { appearances = saved }
        let active = activeName
        let live = currentEmail
        let dirs = (try? fm.contentsOfDirectory(at: accounts, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        let saved: [ProfileRow] = dirs.compactMap { dir in
            guard let id = UUID(uuidString: dir.lastPathComponent), fm.fileExists(atPath: dir.appendingPathComponent("credentials.json").path) else { return nil }
            let email = identityEmail(dir.appendingPathComponent("identity.json"))
            let appearance = appearances[id.uuidString]
            let values = try? dir.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let isCurrent = active == id.uuidString && email?.lowercased() == live?.lowercased() && live != nil
            return ProfileRow(id: id.uuidString, profileID: id, title: appearance?.name?.isEmpty == false ? appearance!.name! : (email ?? "Profile"), email: email, avatarSymbol: appearance?.symbol, avatarColorToken: appearance?.tint, createdAt: values?.creationDate, lastLoadedAt: appearance?.lastLoadedAt, isCurrent: isCurrent, isUnsavedCurrent: false, plan: savedPlan(dir), usage: usage[id.uuidString])
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let migrated = Set(saved.compactMap { $0.profileID })
        let oldRows = legacy.filter { !migrated.contains($0.id) }.map { old in
            let dir = home.appendingPathComponent(".local/share/codex-profiles/claude").appendingPathComponent(old.id.uuidString)
            let email = identityEmail(dir.appendingPathComponent(".claude.json"))
            let appearance = appearances[old.id.uuidString]
            let title = appearance?.name ?? email ?? old.name
            return ProfileRow(id: old.id.uuidString, profileID: old.id, title: title, email: email, avatarSymbol: appearance?.symbol, avatarColorToken: appearance?.tint, createdAt: nil, lastLoadedAt: nil, isCurrent: false, isUnsavedCurrent: false)
        }
        if let live, !saved.contains(where: { $0.isCurrent }) {
            rows = [ProfileRow(id: "current", profileID: nil, title: live, email: live, avatarSymbol: nil, avatarColorToken: nil, createdAt: nil, lastLoadedAt: nil, isCurrent: true, isUnsavedCurrent: true)] + saved + oldRows
        } else { rows = saved + oldRows }
    }
    private func run(_ args: [String], vaultPath: URL? = nil, configDirectory: URL? = nil) throws {
        guard let helper, fm.isExecutableFile(atPath: helper.path) else { throw failure("The Claude switching helper is missing.") }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash"); process.arguments = [helper.path] + args
        var env = ProcessInfo.processInfo.environment
        for key in ["CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"] { env.removeValue(forKey: key) }
        if let configDirectory { env["CLAUDE_CONFIG_DIR"] = configDirectory.path }
        env["CCSWITCH_HOME"] = (vaultPath ?? vault).path; env["CCSWITCH_NO_UPDATE_NOTICE"] = "1"; env["NO_COLOR"] = "1"
        env["PATH"] = home.appendingPathComponent(".local/bin").path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOME"] = home.path
        env.merge(environmentOverrides) { _, override in override }
        process.environment = env
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw failure(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "The operation failed.") }
    }
    private func failure(_ message: String) -> NSError { NSError(domain: "ClaudeProfiles", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    func refreshUsage(interactive: Bool = true) {
        guard !loadingUsage else { return }
        let profiles = rows.filter { row in
            guard let id = row.profileID, fm.fileExists(atPath: accounts.appendingPathComponent(id.uuidString).appendingPathComponent("credentials.json").path) else { return false }
            if interactive { return true }
            return Date().timeIntervalSince(usage[id.uuidString]?.fetchedAt ?? .distantPast) >= 300 && Date().timeIntervalSince(usageAttempts[id.uuidString] ?? .distantPast) >= 300
        }
        guard !profiles.isEmpty else { return }
        loadingUsage = true
        Task {
            defer { loadingUsage = false }
            var failures = 0
            for row in profiles {
                guard let id = row.profileID else { continue }
                let file = accounts.appendingPathComponent(id.uuidString).appendingPathComponent("credentials.json")
                let active = row.isCurrent
                usageAttempts[id.uuidString] = Date()
                let credential = await Task.detached(priority: .utility) { active && interactive ? ClaudeUsageClient.activeCredential() : try? Data(contentsOf: file) }.value
                guard let credential, let token = ClaudeUsageClient.token(from: credential) else { failures += 1; continue }
                do {
                    let result = try await ClaudeUsageClient.fetch(token: token)
                    if active {
                        guard activeName == id.uuidString, currentEmail?.lowercased() == row.email?.lowercased() else { continue }
                    } else {
                        guard (try? Data(contentsOf: file)) == credential else { continue }
                    }
                    usage[id.uuidString] = result
                } catch { failures += 1 }
            }
            if let data = try? JSONEncoder().encode(usage) { defaults.set(data, forKey: "claude_usage_cache_v2") }
            reload()
            if interactive && failures > 0 { errorMessage = "Could not load usage for \(failures) account(s). Sign in again if the login has expired, or try later." }
        }
    }
    func orderedRows(_ order: SortOrder, search: String = "", hideEmails: Bool = false) -> [ProfileRow] {
        let filtered = rows.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || (!hideEmails && ($0.email?.localizedCaseInsensitiveContains(search) ?? false)) }
        let sorted = filtered.sorted { a, b in
            if a.isUnsavedCurrent != b.isUnsavedCurrent { return a.isUnsavedCurrent }
            switch order {
            case .name: return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            case .created: return (a.createdAt ?? .distantPast) > (b.createdAt ?? .distantPast)
            case .recent: return (a.lastLoadedAt ?? a.createdAt ?? .distantPast) > (b.lastLoadedAt ?? b.createdAt ?? .distantPast)
            }
        }
        var shortcut = 0
        return sorted.map { row in
            var value = row
            if row.profileID != nil { if shortcut < 10 { value.shortcutNumber = shortcut }; shortcut += 1 }
            return value
        }
    }
    func signOutLocally() {
        do { try run(["logout-local"]); reload() } catch { errorMessage = error.localizedDescription }
    }
    func saveCurrent() {
        do { try run(["snapshot-current", UUID().uuidString]); reload() } catch { errorMessage = error.localizedDescription }
    }
    func switchTo(_ id: UUID) {
        do {
            if !fm.fileExists(atPath: accounts.appendingPathComponent(id.uuidString).path),
               let old = legacy.first(where: { $0.id == id }) {
                if !rows.contains(where: { $0.isCurrent && !$0.isUnsavedCurrent }), currentEmail != nil {
                    try run(["add", UUID().uuidString]); reload()
                }
                let source = home.appendingPathComponent(".local/share/codex-profiles/claude").appendingPathComponent(id.uuidString)
                let temporary = vault.appendingPathComponent("migration-" + UUID().uuidString)
                defer { try? fm.removeItem(at: temporary) }
                try run(["add", id.uuidString], vaultPath: temporary, configDirectory: source)
                try fm.createDirectory(at: accounts, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try fm.moveItem(at: temporary.appendingPathComponent("accounts").appendingPathComponent(id.uuidString), to: accounts.appendingPathComponent(id.uuidString))
                if identityEmail(source.appendingPathComponent(".claude.json")) == nil {
                    appearances[id.uuidString] = ClaudeAppearance(name: old.name, symbol: nil, tint: nil); persistAppearances()
                }
            }
            if !rows.contains(where: { $0.isCurrent && !$0.isUnsavedCurrent }), currentEmail != nil {
                try run(["add", UUID().uuidString])
            }
            try run(["use", id.uuidString])
            var appearance = appearances[id.uuidString] ?? ClaudeAppearance()
            appearance.lastLoadedAt = Date(); appearances[id.uuidString] = appearance; persistAppearances(); reload()
        } catch { errorMessage = error.localizedDescription; reload() }
    }
    func delete(_ id: UUID) {
        do {
            if fm.fileExists(atPath: accounts.appendingPathComponent(id.uuidString).path) { try run(["rm", id.uuidString]) }
            if var old = try? JSONDecoder().decode([ClaudeLegacyProfile].self, from: defaults.data(forKey: "claude_profiles_v1") ?? Data()) {
                old.removeAll { $0.id == id }
                if let data = try? JSONEncoder().encode(old) { defaults.set(data, forKey: "claude_profiles_v1") }
            }
            appearances.removeValue(forKey: id.uuidString); persistAppearances(); reload()
        } catch { errorMessage = error.localizedDescription }
    }
    func hasSaved(_ id: UUID) -> Bool {
        fm.fileExists(atPath: accounts.appendingPathComponent(id.uuidString).appendingPathComponent("credentials.json").path)
    }
    private func withVaultLock<T>(_ body: () throws -> T) throws -> T {
        try fm.createDirectory(at: vault, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = vault.appendingPathComponent(".profile-switch-lock", isDirectory: true)
        do { try fm.createDirectory(at: lock, withIntermediateDirectories: false) }
        catch { throw failure("Another Claude profile operation is in progress. Try again after it finishes.") }
        defer { try? fm.removeItem(at: lock) }
        try Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8).write(to: lock.appendingPathComponent("pid"))
        return try body()
    }
    func exportProfile(_ id: UUID) {
        do {
            guard hasSaved(id) else { throw failure("Select the earlier profile once to import it before exporting.") }
            let panel = NSSavePanel(); panel.title = "Export Claude Profile"
            let title = (rows.first { $0.profileID == id }?.title ?? "Claude Profile").replacingOccurrences(of: "/", with: "-")
            panel.nameFieldStringValue = title + ".claudeprofile.json"
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            if rows.contains(where: { $0.profileID == id && $0.isCurrent }) { try run(["sync"]) }
            let data = try withVaultLock {
                let folder = accounts.appendingPathComponent(id.uuidString)
                let appearance = appearances[id.uuidString]
                return try ClaudeBackup.encode(credential: Data(contentsOf: folder.appendingPathComponent("credentials.json")), identity: Data(contentsOf: folder.appendingPathComponent("identity.json")), name: appearance?.name, symbol: appearance?.symbol, tint: appearance?.tint)
            }
            try ClaudeBackup.writePrivate(data, to: destination)
        } catch { errorMessage = error.localizedDescription }
    }
    func importProfile() {
        do {
            let panel = NSOpenPanel(); panel.title = "Import Claude Profile"; panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let imported = try ClaudeBackup.decode(Data(contentsOf: url))
            guard !rows.contains(where: { $0.email?.lowercased() == imported.email.lowercased() }) else { throw failure("A Claude profile with this email already exists.") }
            let id = UUID()
            try withVaultLock {
                try fm.createDirectory(at: accounts, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let staging = accounts.appendingPathComponent(".import-" + id.uuidString)
                try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { try? fm.removeItem(at: staging) }
                try ClaudeBackup.writePrivate(imported.credential, to: staging.appendingPathComponent("credentials.json"))
                try ClaudeBackup.writePrivate(imported.identity, to: staging.appendingPathComponent("identity.json"))
                try fm.moveItem(at: staging, to: accounts.appendingPathComponent(id.uuidString))
            }
            appearances[id.uuidString] = ClaudeAppearance(name: imported.name, symbol: imported.symbol, tint: imported.tint); persistAppearances(); reload()
        } catch { errorMessage = error.localizedDescription }
    }
    func update(_ id: UUID, name: String, symbol: String, tint: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var appearance = appearances[id.uuidString] ?? ClaudeAppearance()
        appearance.name = trimmed.isEmpty ? nil : trimmed; appearance.symbol = symbol; appearance.tint = tint
        appearances[id.uuidString] = appearance
        persistAppearances(); reload()
    }
    private func persistAppearances() { if let data = try? JSONEncoder().encode(appearances) { defaults.set(data, forKey: "claude_profile_appearances_v2") } }
    private var claudeExecutable: URL? {
        if let claudeOverride { return claudeOverride }
        return [home.appendingPathComponent(".local/bin/claude"), URL(fileURLWithPath: "/opt/homebrew/bin/claude"), URL(fileURLWithPath: "/usr/local/bin/claude")].first { fm.isExecutableFile(atPath: $0.path) }
    }
    private func isolatedEnvironment(_ directory: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_REFRESH_TOKEN", "CLAUDE_CODE_OAUTH_SCOPES", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_USE_ANTHROPIC_AWS"] { env.removeValue(forKey: key) }
        env["HOME"] = home.path
        env["PATH"] = home.appendingPathComponent(".local/bin").path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env.merge(environmentOverrides) { _, override in override }
        // Always select the new profile even when a caller supplies environment overrides.
        env["CLAUDE_CONFIG_DIR"] = directory.path
        return env
    }
    func login(_ id: UUID? = nil) {
        if id != nil { loginExisting(id!); return }
        guard loginProcess == nil else { return }
        errorMessage = nil
        do {
            guard let executable = claudeExecutable else { throw failure("Claude Code was not found. Install Claude Code and try again.") }
            let profileID = UUID()
            let dir = home.appendingPathComponent(".local/share/codex-profiles/claude", isDirectory: true).appendingPathComponent(profileID.uuidString, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let process = Process(); let output = Pipe(); let input = Pipe()
            process.executableURL = executable; process.arguments = ["auth", "login", "--claudeai"]
            process.environment = isolatedEnvironment(dir); process.standardOutput = output; process.standardError = output; process.standardInput = input
            cancelledLogin = false; loginBuffer = Data(); loginProcess = process; loginInput = input; loginOutput = output
            browserLogin = BrowserLoginState(message: "Complete Claude sign-in in your browser.", authorizationURL: nil)
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                Task { @MainActor [weak self] in self?.receiveLoginOutput(data) }
            }
            process.terminationHandler = { [weak self] process in
                let status = process.terminationStatus
                Task { @MainActor [weak self] in self?.finishIsolatedLogin(id: profileID, directory: dir, status: status) }
            }
            do { try process.run() } catch {
                output.fileHandleForReading.readabilityHandler = nil; loginProcess = nil; loginInput = nil; loginOutput = nil; browserLogin = nil
                try? fm.removeItem(at: dir)
                throw error
            }
        } catch { errorMessage = error.localizedDescription }
    }
    private func receiveLoginOutput(_ data: Data) {
        guard loginProcess != nil else { return }
        loginBuffer.append(data)
        if loginBuffer.count > 65536 { loginBuffer.removeFirst(loginBuffer.count - 65536) }
        guard browserLogin?.authorizationURL == nil, let output = String(data: loginBuffer, encoding: .utf8),
              let range = output.range(of: #"https://[^\s<>\"']+"#, options: .regularExpression),
              let url = URL(string: String(output[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,);]"))),
              let host = url.host?.lowercased(), ["claude.ai", "claude.com", "anthropic.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return }
        browserLogin?.authorizationURL = url
    }
    func submitLoginCode(_ code: String) {
        guard let input = loginInput, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try? input.fileHandleForWriting.write(contentsOf: Data((code.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8))
    }
    func cancelLogin() {
        cancelledLogin = true
        if let process = loginProcess, process.isRunning { process.terminate() }
        browserLogin = nil
    }
    private func finishIsolatedLogin(id: UUID, directory: URL, status: Int32) {
        loginOutput?.fileHandleForReading.readabilityHandler = nil
        try? loginInput?.fileHandleForWriting.close()
        loginProcess = nil; loginInput = nil; loginOutput = nil; loginBuffer = Data(); browserLogin = nil
        if cancelledLogin { return }
        guard status == 0, let email = identityEmail(directory.appendingPathComponent(".claude.json")) else {
            errorMessage = "Claude sign-in did not complete. Please try again. Your current session was not changed."
            return
        }
        var old = (try? JSONDecoder().decode([ClaudeLegacyProfile].self, from: defaults.data(forKey: "claude_profiles_v1") ?? Data())) ?? []
        old.append(ClaudeLegacyProfile(id: id, name: email, isDefault: false))
        if let data = try? JSONEncoder().encode(old) { defaults.set(data, forKey: "claude_profiles_v1") }
        reload()
    }
    private func loginExisting(_ id: UUID) {
        do {
            guard let helper else { throw failure("The Claude switching helper is missing.") }
            if !rows.contains(where: { $0.isCurrent && !$0.isUnsavedCurrent }), currentEmail != nil { try run(["add", UUID().uuidString]); reload() }
            let name = id.uuidString
            let executablePath = home.appendingPathComponent(".local/bin").path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            let cmd = "env -u CLAUDE_CONFIG_DIR -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN CCSWITCH_HOME=" + ClaudeSupport.quote(vault.path) + " CCSWITCH_NO_UPDATE_NOTICE=1 PATH=" + ClaudeSupport.quote(executablePath) + " /bin/bash " + ClaudeSupport.quote(helper.path) + " login " + ClaudeSupport.quote(name)
            let script = "tell application \"Terminal\"\nactivate\ndo script \"" + cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"\nend tell"
            var error: NSDictionary?; guard let apple = NSAppleScript(source: script) else { throw failure("Could not open Terminal.") }
            apple.executeAndReturnError(&error)
            if let error { throw failure(error.description) }
            reload()
        } catch { errorMessage = error.localizedDescription }
    }
}
