import SwiftUI

extension Notification.Name {
    static let saveCurrentClaudeProfile = Notification.Name("saveCurrentClaudeProfile")
    static let loginClaudeProfile = Notification.Name("loginClaudeProfile")
    static let refreshClaudeUsage = Notification.Name("refreshClaudeUsage")
}

struct ClaudeProfilesView: View {
    var searchText: String
    @ObservedObject var model: ClaudeSwitchModel
    @AppStorage("hide_emails") private var hideEmails = false
    @AppStorage("sort_order") private var sortOrderRaw = SortOrder.recent.rawValue
    @State private var editID: UUID?
    @State private var name = ""
    @State private var symbol = AvatarOption.person.rawValue
    @State private var tint = AvatarTintOption.blue.rawValue

    private var rows: [ProfileRow] {
        model.orderedRows(SortOrder(rawValue: sortOrderRaw) ?? .recent, search: searchText, hideEmails: hideEmails)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(rows) { row in
                    ProfileRowView(row: row, hideEmails: hideEmails, canRenew: false, isBusy: model.busy,
                        renameAction: {
                            guard let id = row.profileID else { return }
                            editID = id; name = row.title
                            symbol = row.avatarSymbol ?? AvatarOption.person.rawValue
                            tint = row.avatarColorToken ?? AvatarTintOption.blue.rawValue
                        },
                        loadAction: { if let id = row.profileID { model.switchTo(id) } },
                        deleteAction: { if let id = row.profileID { model.delete(id) } },
                        exportAction: { if let id = row.profileID { model.exportProfile(id) } }, detailsAction: {}, renewAction: {},
                        signInAction: { model.login(row.profileID) },
                        addAction: { model.saveCurrent() }, claudeMode: true, claudeCanExport: row.profileID.map { model.hasSaved($0) } ?? false)

                }
                if rows.isEmpty {
                    Text(searchText.isEmpty ? "No saved profiles" : "No matching profiles").font(.headline)
                    Text("Sign in to add a Claude Code account.").foregroundStyle(.secondary)
                    Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 22, weight: .medium)).foregroundStyle(.secondary).padding(.top, 80)
                }
            }.padding(10)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.login() } label: { Label("Sign In New Profile", systemImage: "person.crop.circle.badge.plus") }
                    .help("Add Claude account with browser sign-in")
                Button { model.importProfile() } label: { Label("Import Profiles", systemImage: "square.and.arrow.down") }
                    .help("Import a Claude profile backup")
                Button { model.saveCurrent() } label: { Label("Save Current Profile", systemImage: "tray.and.arrow.down") }
                    .disabled(!model.rows.contains(where: { $0.isUnsavedCurrent }))
                    .help("Save current Claude account")
                Button { model.signOutLocally() } label: { Label("Sign Out Locally", systemImage: "rectangle.portrait.and.arrow.right") }
                    .disabled(!model.rows.contains(where: { $0.isCurrent && !$0.isUnsavedCurrent }))
                    .help("Sign out locally, preserving the saved Claude profile")
                Button { model.refreshUsage() } label: { Label("Refresh Limits", systemImage: "arrow.clockwise") }
                    .disabled(model.loadingUsage)
                    .help("Refresh Claude usage limits")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveCurrentClaudeProfile)) { _ in model.saveCurrent() }
        .onReceive(NotificationCenter.default.publisher(for: .loginClaudeProfile)) { _ in model.login() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshClaudeUsage)) { _ in model.refreshUsage() }
        .onAppear { model.reload(); model.refreshUsage(interactive: false) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.reload() }
        .sheet(isPresented: Binding(get: { editID != nil }, set: { if !$0 { editID = nil } })) {
            NamePromptView(draftName: $name, draftAvatarSymbol: $symbol, draftAvatarColorToken: $tint,
                confirmAction: { if let id = editID { model.update(id, name: name, symbol: symbol, tint: tint) }; editID = nil },
                cancelAction: { editID = nil })
        }
        .sheet(isPresented: Binding(get: { model.browserLogin != nil }, set: { if !$0 { model.cancelLogin() } })) {
            if let login = model.browserLogin {
                ClaudeBrowserLoginView(state: login, openAction: { if let url = login.authorizationURL { NSWorkspace.shared.open(url) } }, submitAction: { model.submitLoginCode($0) }, cancelAction: { model.cancelLogin() })
            }
        }
        .alert("Claude Code", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}

private struct ClaudeBrowserLoginView: View {
    let state: BrowserLoginState
    let openAction: () -> Void
    let submitAction: (String) -> Void
    let cancelAction: () -> Void
    @State private var code = ""
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "globe").font(.system(size: 22, weight: .medium)).foregroundStyle(.secondary)
            Text(state.message).font(.system(size: 13, weight: .medium))
            if let url = state.authorizationURL {
                Text(url.absoluteString).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
            } else { ProgressView().controlSize(.small) }
            SecureField("Authorization code (if requested)", text: $code).textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button("Cancel", action: cancelAction).keyboardShortcut(.cancelAction)
                Spacer()
                if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Submit Code") { submitAction(code); code = "" }
                }
                if state.authorizationURL != nil {
                    Button(action: openAction) { Image(systemName: "arrow.up.forward.app").frame(width: 28, height: 28) }
                        .help("Open sign-in in browser")
                }
            }
        }.padding(18).frame(width: 320)
    }
}
