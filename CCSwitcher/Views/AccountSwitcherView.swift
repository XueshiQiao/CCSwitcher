import SwiftUI

/// Lists all configured accounts with switching and management.
struct AccountSwitcherView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showingAddConfirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if appState.accounts.isEmpty {
                    emptyState
                } else {
                    ForEach(appState.accounts) { account in
                        accountRow(account)
                    }
                }

                addAccountButtons
            }
            .padding(16)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("No Accounts")
                .font(.headline)

            Text("Add your current Claude Code account to get started.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                HStack(spacing: 6) {
                    Text(account.obfuscatedDisplayName)
                        .font(.subheadline.weight(.medium))

                    if account.isActive {
                        Text("Active")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green, in: Capsule())
                    }
                }

                Text(account.obfuscatedEmail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if let sub = account.subscriptionType {
                        Label(sub, systemImage: "creditcard")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(account.provider.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
                .strokeBorder(account.isActive ? .cardBorderBrand : .cardBorderNeutral, lineWidth: 1)
        )
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
                    .foregroundStyle(.secondary)
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
                    .strokeBorder(.cardBorderBrand, lineWidth: 1)
            )
        } else if showingAddConfirm {
            // Inline confirmation for "Add Current"
            VStack(spacing: 8) {
                Text("This will capture the currently logged-in Claude Code account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    .strokeBorder(.cardBorderBrand, lineWidth: 1)
            )
        } else {
            VStack(spacing: 8) {
                // Primary: Login new account via browser
                Button {
                    Task { await appState.loginNewAccount() }
                } label: {
                    Label("Login New Account", systemImage: "person.badge.plus")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.brand)

                // Secondary: Capture already-logged-in account
                Button {
                    withAnimation { showingAddConfirm = true }
                } label: {
                    Label("Add Current Account", systemImage: "plus.circle")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}
