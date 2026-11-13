import SwiftUI
import AppKit

private struct ClaudeAccount: Codable, Identifiable {
    var id: UUID
    var name: String
    var isDefault: Bool
}

struct ClaudeProfilesView: View {
    @State private var accounts: [ClaudeAccount] = loadAccounts()
    @State private var name = ""
    @State private var adding = false
    @State private var message: String?

    private static let key = "claude_profiles_v1"
    private static func loadAccounts() -> [ClaudeAccount] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let accounts = try? JSONDecoder().decode([ClaudeAccount].self, from: data) else {
            return [ClaudeAccount(id: UUID(), name: "Current Claude account", isDefault: true)]
        }
        return accounts
    }
    private func save() {
        if let data = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
    private func launch(_ account: ClaudeAccount, continuing: Bool = false) {
        let panel = NSOpenPanel()
        panel.title = "Choose a project folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let project = panel.url else { return }
        do {
            let fm = FileManager.default
            let base = fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/codex-profiles/claude", isDirectory: true)
            let dir = base.appendingPathComponent(account.id.uuidString, isDirectory: true)
            if !account.isDefault { try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            let global = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
            var mcpPath: String?
            if !account.isDefault, fm.fileExists(atPath: global.path) {
                let servers = try ClaudeSupport.servers(from: Data(contentsOf: global), project: project)
                if !servers.isEmpty {
                    let config = dir.appendingPathComponent("shared-mcp.json")
                    let content = try JSONSerialization.data(withJSONObject: ["mcpServers": servers])
                    try content.write(to: config, options: .atomic)
                    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
                    mcpPath = config.path
                }
            }
            let path = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path].first(where: { fm.isExecutableFile(atPath: $0) })
            guard let executable = path else { throw NSError(domain: "Claude", code: 1, userInfo: [NSLocalizedDescriptionKey: "Claude Code was not found."]) }
            var resumePath: String?
            if continuing {
                let roots = accounts.map { source in
                    (source.name, source.isDefault ? fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude") : base.appendingPathComponent(source.id.uuidString))
                }
                let sessions = ClaudeSupport.sessions(roots: roots, project: project)
                guard !sessions.isEmpty else { message = "No saved conversations were found for this folder."; return }
                let chooser = NSAlert()
                chooser.messageText = "Choose a conversation to continue"
                chooser.informativeText = "A copy opens with the selected account. Your original conversation stays in place."
                let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26))
                let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short
                for session in sessions.prefix(100) {
                    popup.addItem(withTitle: "\(session.account) · \(formatter.string(from: session.modified)) · \(session.url.deletingPathExtension().lastPathComponent.prefix(8))")
                }
                chooser.accessoryView = popup
                chooser.addButton(withTitle: "Continue")
                chooser.addButton(withTitle: "Cancel")
                guard chooser.runModal() == .alertFirstButtonReturn, popup.indexOfSelectedItem >= 0 else { return }
                resumePath = sessions[popup.indexOfSelectedItem].url.resolvingSymlinksInPath().path
            }
            let command = ClaudeSupport.command(executable: executable, project: project.path, configDirectory: account.isDefault ? nil : dir.path, mcpConfig: mcpPath, resumeFile: resumePath)
            let script = "tell application \"Terminal\"\n activate\n do script " + "\"" + command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"\nend tell"
            var error: NSDictionary?
            guard let apple = NSAppleScript(source: script) else { throw NSError(domain: "Terminal", code: 1) }
            apple.executeAndReturnError(&error)
            if let error = error { throw NSError(domain: "Terminal", code: 1, userInfo: [NSLocalizedDescriptionKey: error.description]) }
        } catch { message = error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Claude Code accounts").font(.headline)
                Spacer()
                Button("Add Account") { name = ""; adding = true }
            }
            Text("Open an account in Terminal, or continue a saved conversation with it. New accounts sign in on first launch. MCP definitions from your existing setup are shared; server sign-ins may be needed again.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
              LazyVStack(spacing: 8) {
              ForEach(accounts) { account in
                HStack {
                    Image(systemName: "person.crop.circle")
                    VStack(alignment: .leading) {
                        Text(account.name)
                        Text(account.isDefault ? "Existing Claude Code setup" : "Separate Claude Code sign-in").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Switch & Continue…") { launch(account, continuing: true) }
                    Button("Open") { launch(account) }
                    if !account.isDefault {
                        Button(role: .destructive) {
                            let confirm = NSAlert(); confirm.messageText = "Remove this account from the list?"
                            confirm.informativeText = "Its sign-in and conversation files remain on this Mac. Removing it here makes it inaccessible from this list."
                            confirm.addButton(withTitle: "Remove"); confirm.addButton(withTitle: "Cancel")
                            if confirm.runModal() == .alertFirstButtonReturn { accounts.removeAll { $0.id == account.id }; save() }
                        } label: { Image(systemName: "minus.circle") }
                            .help("Remove from list; account data is kept")
                    }
                }.padding(10).background(Color(nsColor: .controlBackgroundColor)).cornerRadius(8)
            }
              }
            }
        }.padding(14)
        .sheet(isPresented: $adding) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Add Claude account").font(.headline)
                TextField("Account name", text: $name)
                Text("Claude Code will ask you to sign in when you open it.").font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button("Cancel") { adding = false }; Button("Add") {
                    accounts.append(ClaudeAccount(id: UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), isDefault: false)); save(); adding = false
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || accounts.contains { $0.name.localizedCaseInsensitiveCompare(name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }) }
            }.padding(20).frame(width: 360)
        }
        .alert("Claude Code", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") { message = nil } } message: { Text(message ?? "") }
    }
}
