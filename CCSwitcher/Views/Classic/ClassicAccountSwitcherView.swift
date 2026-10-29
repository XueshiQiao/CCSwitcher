import AppKit
import SwiftUI

/// The 1.x Accounts tab: all configured accounts with switching and management.
struct ClassicAccountSwitcherView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("showFullEmail") private var showFullEmail = false
    @State private var showingAddConfirm = false
    @State private var editingAccountId: UUID?
    @State private var editingLabel = ""
    @State private var copiedLoginURL = false
    /// Bumped per copy, so only the latest copy's timer clears "Copied!".
    @State private var copyGeneration = 0
    /// The account whose trash button was clicked; its row asks to confirm.
    @State private var confirmingRemoveId: UUID?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.panelShown) private var panelShown

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
        // Don't greet the next opening of the panel with a pending removal.
        .onChange(of: panelShown) { _, shown in
            if !shown { confirmingRemoveId = nil }
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
            Image(systemName: account.provider.iconName)
                .font(.title2)
                .foregroundStyle(account.isActive ? Classic.brand : .textSecondary)
                .frame(width: 32, height: 32)

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
                        .accessibilityLabel("Save")

                        Button {
                            editingAccountId = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Cancel")
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
                        .accessibilityLabel("Edit label")

                        if account.isActive {
                            ClassicBadge(text: String(localized: "Active", bundle: L10n.bundle), color: .green)
                        }
                    }
                }

                Text(account.displayEmail(obfuscated: !showFullEmail))
                    .font(.caption)
                    .foregroundStyle(.textSecondary)

                // One line: the plan keeps its width and the provider name
                // truncates instead of the plan wrapping mid-word.
                HStack(spacing: 8) {
                    if let sub = account.displaySubscriptionType {
                        Label(sub, systemImage: "creditcard")
                            .font(.caption2)
                            .foregroundStyle(.textSecondary)
                            .fixedSize()
                    }
                    Text(account.provider.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.textSecondary)
                }
                .lineLimit(1)
            }
            // The confirmation buttons are wider than the ones they replace;
            // keep the text to one line meanwhile so the row can't grow.
            .lineLimit(confirmingRemoveId == account.id ? 1 : nil)

            Spacer()

            if confirmingRemoveId == account.id {
                // Confirm in place, where the buttons were: an alert would
                // take key status from the panel and close it.
                Button("Cancel") {
                    confirmingRemoveId = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()

                Button("Remove", role: .destructive) {
                    confirmingRemoveId = nil
                    appState.removeAccount(account)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.red)
                .fixedSize()
                .help("Remove account")
            } else {
                if !account.isActive {
                    Button("Switch") {
                        Task { await appState.switchTo(account) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Classic.brand)
                    .fixedSize()
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
                .accessibilityLabel("Re-authenticate (fix stale token)")

                Button {
                    confirmingRemoveId = account.id
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Remove account")
                .accessibilityLabel("Remove account")
            }
        }
        .padding(12)
        .background(cardBackground(fill: account.isActive ? .cardFillStrong : .clear))
    }

    private func cardBackground(fill: Color) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(fill)
            .strokeBorder(.cardBorder, lineWidth: 1)
            .shadow(color: AppStyle.cardShadowColor, radius: AppStyle.cardShadowRadius, x: 0, y: AppStyle.cardShadowY)
    }

    private func commitLabelEdit(_ account: Account) {
        appState.updateAccountLabel(account, label: editingLabel)
        editingAccountId = nil
    }

    // MARK: - Add Account Buttons

    @ViewBuilder
    private var addAccountButtons: some View {
        if appState.isLoggingIn {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for browser login...")
                    .font(.caption)
                    .foregroundStyle(.textSecondary)
                Text("Complete the login in your browser, then return here.")
                    .font(.caption2)
                    .foregroundStyle(Classic.tertiaryText)
                    .multilineTextAlignment(.center)

                // Added after 1.x: copy the login link (for another browser)
                // and stop a login that is waiting on a closed browser tab.
                HStack(spacing: 12) {
                    if let authURL = appState.loginAuthURL {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(authURL.absoluteString, forType: .string)
                            copiedLoginURL = true
                            copyGeneration += 1
                            let generation = copyGeneration
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                if copyGeneration == generation { copiedLoginURL = false }
                            }
                        } label: {
                            Label(
                                copiedLoginURL ? "Copied!" : "Copy Login URL",
                                systemImage: copiedLoginURL ? "checkmark" : "doc.on.doc"
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .focusable(false)
                    }

                    Button("Cancel") {
                        copiedLoginURL = false
                        appState.cancelLogin()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .focusable(false)
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(cardBackground(fill: .cardFillStrong))
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
                    .tint(Classic.brand)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .background(cardBackground(fill: .cardFillStrong))
        } else {
            VStack(spacing: 8) {
                // Primary: log in a new account via the browser
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

                // Secondary: capture the already-logged-in account
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
