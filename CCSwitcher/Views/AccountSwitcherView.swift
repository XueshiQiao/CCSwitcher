import SwiftUI

/// Account management and stored quota share one card per account.
struct AccountSwitcherView: View {
    var showRecycled = false
    @EnvironmentObject private var appState: AppState
    @AppStorage("showFullEmail") private var showFullEmail = false
    @State private var showingAddConfirm = false
    @State private var editingAccount: Account?
    @State private var copiedLoginURL = false


    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 8) {
                    if displayedAccounts.isEmpty {
                        emptyState
                    } else {
                        ForEach(displayedAccounts) { account in
                            accountRow(account)
                        }
                    }
                    if !showRecycled {
                        DisclosureGroup("Local statistics") {
                            LocalUsageSummaryView()
                                .padding(.top, 8)
                        }
                        .font(.caption)
                    }
                }
                .padding(12)
            }
            if !showRecycled {
                Divider()
                addAccountButtons
                    .padding(12)
            }
        }
        .sheet(item: $editingAccount) { account in
            AccountEditView(account: account)
                .environmentObject(appState)
        }
    }

    private var displayedAccounts: [Account] {
        showRecycled ? appState.recycledAccounts : appState.visibleAccounts
    }

    private var actionsBusy: Bool {
        appState.isLoggingIn || appState.isSwitching || appState.isLoading
            || !appState.refreshingUsageAccountIDs.isEmpty
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: showRecycled ? "archivebox" : "person.crop.circle.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(.textSecondary)

            Text(LocalizedStringKey(showRecycled ? "No recycled accounts" : "No Accounts"))
                .font(.headline)

            Text(LocalizedStringKey(showRecycled ? "Accounts you recycle will appear here." : "Add your current Claude Code account to get started."))
                .font(.caption)
                .foregroundStyle(.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Account Row

    private func accountRow(_ account: Account) -> some View {
        let current = account.id == appState.activeAccount?.id && !showRecycled
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if current {
                    Label("Current account", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .help("Current account")
                }
                Text(account.displayEmail(obfuscated: !showFullEmail))
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let subscription = account.displaySubscriptionType {
                    Text(subscription).foregroundStyle(.secondary)
                }
                CopyEmailButton(email: account.email)
                if !current {
                    Button(LocalizedStringKey(showRecycled ? "Restore account" : "Switch")) {
                        if showRecycled { appState.restoreAccount(account) }
                        else { Task { await appState.switchTo(account) } }
                    }
                    .buttonStyle(.borderless)
                    .disabled(actionsBusy)
                }
                Menu {
                    Button("Edit account") { editingAccount = account }
                    if !showRecycled {
                        Button("Re-authenticate (fix stale token)") {
                            Task { await appState.reauthenticateAccount(account) }
                        }
                        Button("Recycle account") { appState.recycleAccount(account) }
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 20, height: 16)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Account actions")
                .accessibilityLabel("Account actions")
                .disabled(actionsBusy)
            }
            .font(.caption)
            .controlSize(.small)

            if let label = account.customLabel, !label.isEmpty {
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
            AccountUsageView(account: account)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(current ? Color.accentColor : Color.primary.opacity(0.07), lineWidth: current ? 2 : 1)
        }
    }

    // MARK: - Add Account Buttons

    @ViewBuilder
    private var addAccountButtons: some View {
        if appState.isLoggingIn {
            // Logging in state
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for browser login...")
                    .font(.caption)
                    .foregroundStyle(.textSecondary)
                if let url = appState.loginURL {
                    Button {
                        NSPasteboard.general.clearContents()
                        copiedLoginURL = NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    } label: {
                        Label(LocalizedStringKey(copiedLoginURL ? "Login address copied" : "Copy login address"), systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Text("Copy the address into your preferred browser to sign in, then return here.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                } else if appState.canCancelLogin {
                    Text("Preparing login address...")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if appState.canCancelLogin || appState.isCancellingLogin {
                    Button(LocalizedStringKey(appState.isCancellingLogin ? "Cancelling..." : "Cancel login")) {
                        appState.cancelLogin()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(appState.isCancellingLogin)
                } else {
                    Text("Finishing sign-in...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: appState.loginURL) { _, _ in copiedLoginURL = false }
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.cardFillStrong)
                    .strokeBorder(.cardBorder, lineWidth: 1)
                    .shadow(color: AppStyle.cardShadowColor, radius: AppStyle.cardShadowRadius, x: 0, y: AppStyle.cardShadowY)
            )
        } else if showingAddConfirm {
            // Inline confirmation for "Add Current"
            VStack(spacing: 8) {
                Text("This will capture the currently logged-in Claude Code account.")
                    .font(.caption)
                    .foregroundStyle(.textSecondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Button("Cancel") {
                        withAnimation { showingAddConfirm = false }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Add Account") {
                        showingAddConfirm = false
                        Task { await appState.addAccount() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.brand)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.cardFillStrong)
                    .strokeBorder(.cardBorder, lineWidth: 1)
                    .shadow(color: AppStyle.cardShadowColor, radius: AppStyle.cardShadowRadius, x: 0, y: AppStyle.cardShadowY)
            )
        } else {
            HStack(spacing: 8) {
                Button {
                    Task { await appState.loginNewAccount() }
                } label: {
                    Label("Login New Account", systemImage: "person.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    showingAddConfirm = true
                } label: {
                    Label("Add Current Account", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(actionsBusy)
        }
    }
}
