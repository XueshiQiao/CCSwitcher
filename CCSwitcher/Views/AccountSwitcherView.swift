import SwiftUI

/// Lists all configured accounts with switching and management.
struct AccountSwitcherView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("showFullEmail") private var showFullEmail = false
    @State private var showingAddConfirm = false
    @State private var editingAccountId: UUID?
    @State private var editingLabel = ""

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    if appState.accounts.isEmpty {
                        emptyState
                    } else {
                        ForEach(appState.accounts) { account in
                            accountRow(account)
                        }
                    }
                }
                .padding(16)
            }

            addAccountButtons
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .padding(.top, 8)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(.textSecondary)

            Text("No Accounts")
                .font(.headline)

            Text("Add your current Claude Code account to get started.")
                .font(.caption)
                .foregroundStyle(.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Account Row

    private func accountRow(_ account: Account) -> some View {
        HStack(spacing: 12) {
            // Provider icon
            Image(systemName: account.provider.iconName)
                .font(.title2)
                .foregroundStyle(account.isActive ? .brand : .secondary)
                .frame(width: 32, height: 32)

            // Account info
            VStack(alignment: .leading, spacing: 2) {
                if editingAccountId == account.id {
                    HStack(spacing: 4) {
                        TextField("Custom label", text: $editingLabel)
                            .textFieldStyle(.roundedBorder)
                            .font(.subheadline)
                            .onSubmit { commitLabelEdit(account) }

                        Button {
                            commitLabelEdit(account)
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)

                        Button {
                            editingAccountId = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(account.effectiveDisplayName(obfuscated: !showFullEmail))
                            .font(.subheadline.weight(.medium))

                        Button {
                            editingLabel = account.customLabel ?? ""
                            editingAccountId = account.id
                        } label: {
                            Image(systemName: "pencil")
                                .font(.caption2)
                                .foregroundStyle(.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Edit label")

                        if account.isActive {
                            Badge(text: String(localized: "Active", bundle: L10n.bundle), color: .green)
                        }
                    }
                }

                Text(account.displayEmail(obfuscated: !showFullEmail))
                    .font(.caption)
                    .foregroundStyle(.textSecondary)

                HStack(spacing: 8) {
                    if let sub = account.displaySubscriptionType {
                        Label(sub, systemImage: "creditcard")
                            .font(.caption2)
                            .foregroundStyle(.textSecondary)
                    }
                    Text(account.provider.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.textSecondary)
                }
            }

            Spacer()

            // Actions
            if !account.isActive {
                Button("Switch") {
                    Task { await appState.switchTo(account) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.brand)
            }

            Button {
                Task { await appState.reauthenticateAccount(account) }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help("Re-authenticate (fix stale token)")

            Button {
                appState.removeAccount(account)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Remove account")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(account.isActive ? .cardFillStrong : .clear)
                .strokeBorder(.cardBorder, lineWidth: 1)
                .shadow(color: AppStyle.cardShadowColor, radius: AppStyle.cardShadowRadius, x: 0, y: AppStyle.cardShadowY)
        )
    }

    private func commitLabelEdit(_ account: Account) {
        appState.updateAccountLabel(account, label: editingLabel)
        editingAccountId = nil
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
                Text("Complete the login in your browser, then return here.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
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
            VStack(spacing: 8) {
                // Primary: Login new account via browser
                Button {
                    Task { await appState.loginNewAccount() }
                } label: {
                    Label("Login New Account", systemImage: "person.badge.plus")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(AppStyle.buttonTextColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                // Secondary: Capture already-logged-in account
                Button {
                    withAnimation { showingAddConfirm = true }
                } label: {
                    Label("Add Current Account", systemImage: "plus.circle")
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    colorScheme == .dark
                                        ? Color.gray.opacity(0.4)
                                        : Color.white.opacity(0.22),
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
