import SwiftUI
import AppKit

/// Lists all configured accounts with switching and management.
struct AccountSwitcherView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("showFullEmail") private var showFullEmail = false
    @State private var showingAddConfirm = false
    @State private var editingAccountId: UUID?
    @State private var editingLabel = ""
    @State private var copiedLoginURL = false
    /// Bumped per copy, so only the latest copy's timer clears "Copied!".
    @State private var copyGeneration = 0

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 8) {
                    if appState.accounts.isEmpty {
                        emptyState
                    } else {
                        ForEach(appState.accounts) { account in
                            AccountRow(
                                account: account,
                                showFullEmail: showFullEmail,
                                isEditing: editingAccountId == account.id,
                                editingLabel: $editingLabel,
                                onBeginEdit: {
                                    editingLabel = account.customLabel ?? ""
                                    withAnimation(Theme.ease) { editingAccountId = account.id }
                                },
                                onCommitEdit: { commitLabelEdit(account) },
                                onCancelEdit: { withAnimation(Theme.ease) { editingAccountId = nil } },
                                onSwitch: { Task { await appState.switchTo(account) } },
                                onReauth: { Task { await appState.reauthenticateAccount(account) } },
                                onRemove: { appState.removeAccount(account) }
                            )
                        }
                    }
                }
                .padding(.horizontal, Theme.pad)
                .padding(.top, 6)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)

            addAccountButtons
                .padding(.horizontal, Theme.pad)
                .padding(.bottom, 12)
                .padding(.top, 4)
                .animation(Theme.ease, value: showingAddConfirm)
                .animation(Theme.ease, value: appState.isLoggingIn)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.glow)
                .frame(width: 64, height: 64)
                .surface(radius: 32)

            Text("No Accounts")
                .font(.headline)

            Text("Add your current Claude Code account to get started.")
                .font(.caption)
                .foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private func commitLabelEdit(_ account: Account) {
        appState.updateAccountLabel(account, label: editingLabel)
        withAnimation(Theme.ease) { editingAccountId = nil }
    }

    // MARK: - Add Account Buttons

    @ViewBuilder
    private var addAccountButtons: some View {
        if appState.isLoggingIn {
            // Logging in state
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for browser login...")
                    .font(.caption.weight(.medium))
                Text("Complete the login in your browser, then return here.")
                    .font(.caption2)
                    .foregroundStyle(Theme.dim)
                    .multilineTextAlignment(.center)

                HStack(spacing: 8) {
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
                        .buttonStyle(SecondaryButtonStyle())
                        .focusable(false)
                    }

                    Button("Cancel") {
                        copiedLoginURL = false
                        appState.cancelLogin()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .focusable(false)
                }
            }
            .frame(maxWidth: .infinity)
            .card(padding: 14)
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
        } else if showingAddConfirm {
            // Inline confirmation for "Add Current"
            VStack(spacing: 10) {
                Text("This will capture the currently logged-in Claude Code account.")
                    .font(.caption)
                    .foregroundStyle(Theme.dim)
                    .multilineTextAlignment(.center)

                HStack(spacing: 8) {
                    Button("Cancel") {
                        showingAddConfirm = false
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Button("Add Account") {
                        showingAddConfirm = false
                        Task { await appState.addAccount() }
                    }
                    .buttonStyle(PrimaryButtonStyle(height: 32))
                }
            }
            .frame(maxWidth: .infinity)
            .card(padding: 14)
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
        } else {
            VStack(spacing: 8) {
                // Primary: Login new account via browser
                Button {
                    Task { await appState.loginNewAccount() }
                } label: {
                    Label("Login New Account", systemImage: "person.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(height: 38, fillsWidth: true))
                .focusable(false)

                // Capture already-logged-in account
                Button {
                    showingAddConfirm = true
                } label: {
                    Label("Add Current Account", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(height: 38, fillsWidth: true))
                .focusable(false)
            }
            .transition(.opacity)
        }
    }
}

// MARK: - Account Row

private struct AccountRow: View {
    let account: Account
    let showFullEmail: Bool
    let isEditing: Bool
    @Binding var editingLabel: String
    let onBeginEdit: () -> Void
    let onCommitEdit: () -> Void
    let onCancelEdit: () -> Void
    let onSwitch: () -> Void
    let onReauth: () -> Void
    let onRemove: () -> Void

    @State private var hover = false
    @State private var confirmingRemove = false
    @FocusState private var fieldFocused: Bool
    @Environment(\.panelShown) private var panelShown

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: account.effectiveDisplayName(obfuscated: !showFullEmail),
                   icon: account.provider.iconName, active: account.isActive, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                if isEditing {
                    labelEditor
                } else {
                    HStack(spacing: 6) {
                        Text(account.effectiveDisplayName(obfuscated: !showFullEmail))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)

                        Button(action: onBeginEdit) {
                            Image(systemName: "pencil")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.dim)
                        }
                        .buttonStyle(PressStyle())
                        .opacity(hover ? 1 : 0)
                        .help("Edit label")
                        .accessibilityLabel("Edit label")

                        if account.isActive {
                            Badge(text: String(localized: "Active", bundle: L10n.bundle), color: Theme.success)
                        }
                    }
                }

                Text(account.displayEmail(obfuscated: !showFullEmail))
                    .font(.caption)
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)

                // One line: with the row's buttons beside it the plan name used
                // to wrap mid-word ("Tea" / "m"). The plan keeps its width and
                // the provider name truncates instead.
                HStack(spacing: 8) {
                    if let sub = account.displaySubscriptionType {
                        Label(sub, systemImage: "creditcard")
                            .fixedSize()
                    }
                    Text(account.provider.rawValue)
                }
                .lineLimit(1)
                .font(.caption2)
                .foregroundStyle(Theme.dim)
            }

            Spacer(minLength: 4)

            // Actions
            HStack(spacing: 6) {
                if confirmingRemove {
                    // Confirm in place, in the same space as the regular
                    // actions: an alert or sheet would take key status from
                    // the panel and close it.
                    Button("Cancel") {
                        withAnimation(Theme.ease) { confirmingRemove = false }
                    }
                    .buttonStyle(SecondaryButtonStyle(height: 28))
                    .fixedSize()
                    .focusable(false)

                    Button("Remove") {
                        confirmingRemove = false
                        onRemove()
                    }
                    .buttonStyle(SecondaryButtonStyle(height: 28, tint: Theme.danger))
                    .fixedSize()
                    .focusable(false)
                    .help("Remove account")
                } else {
                    if !account.isActive {
                        Button("Switch", action: onSwitch)
                            .buttonStyle(PrimaryButtonStyle(height: 28))
                            .focusable(false)
                    }

                    CircleIconButton(icon: "arrow.triangle.2.circlepath", label: "Re-authenticate (fix stale token)",
                                     size: 26, tint: Theme.warning, action: onReauth)

                    CircleIconButton(icon: "trash", label: "Remove account", size: 26, tint: Theme.danger) {
                        withAnimation(Theme.ease) { confirmingRemove = true }
                    }
                }
            }
        }
        .padding(12)
        .surface(fill: account.isActive ? Theme.accent.opacity(0.10) : (hover ? Theme.cardHover : Theme.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .strokeBorder(Theme.accent.opacity(account.isActive ? 0.45 : 0), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
        .animation(Theme.ease, value: account.isActive)
        // Don't greet the next opening of the panel with a pending removal.
        .onChange(of: panelShown) { _, shown in
            if !shown { confirmingRemove = false }
        }
    }

    private var labelEditor: some View {
        HStack(spacing: 6) {
            TextField("Custom label", text: $editingLabel)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .focused($fieldFocused)
                .onSubmit(onCommitEdit)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.well)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Theme.accent.opacity(fieldFocused ? 0.7 : 0.2), lineWidth: 1)
                        )
                )
                .onAppear { fieldFocused = true }

            Button(action: onCommitEdit) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Save")

            Button(action: onCancelEdit) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.dim)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Cancel")
        }
    }
}
