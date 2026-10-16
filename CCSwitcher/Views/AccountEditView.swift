import SwiftUI

struct AccountEditView: View {
    let account: Account
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("showFullEmail") private var showFullEmail = false
    @State private var label: String
    @State private var showAuthorization = false
    @State private var authorization: StoredAuthorization?

    init(account: Account) {
        self.account = account
        _label = State(initialValue: account.customLabel ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit account")
                .font(.headline)
            HStack {
                Text(account.displayEmail(obfuscated: !showFullEmail))
                    .foregroundStyle(.secondary)
                CopyEmailButton(email: account.email)
            }
            TextField("Custom label", text: $label)
                .textFieldStyle(.roundedBorder)

            Divider()
            Text("Account backup")
                .font(.subheadline.weight(.medium))
            Text("View the saved token and OAuth identity for this account. This is a read-only backup, not the current CLI credentials.")
                .font(.caption)
                .foregroundStyle(.secondary)

            DisclosureGroup("Show saved authorization", isExpanded: $showAuthorization) {
                authorizationContent
                    .padding(.top, 8)
            }
            .task(id: showAuthorization) {
                guard showAuthorization, authorization == nil else { return }
                let accountID = account.id
                let result = await Task.detached {
                    StoredAuthorization.load(accountID: accountID)
                }.value
                guard !Task.isCancelled else { return }
                authorization = result
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    appState.updateAccountLabel(account, label: label)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder
    private var authorizationContent: some View {
        switch authorization {
        case nil:
            ProgressView()
                .controlSize(.small)
        case .json(let json):
            ScrollView([.horizontal, .vertical]) {
                Text(verbatim: json)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 260)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        case .missing:
            Text("No authorization backup is stored for this account.")
                .foregroundStyle(.secondary)
        case .unavailable:
            Text("The authorization store is unavailable. Unlock the keychain or allow access, then close and reopen this editor.")
                .foregroundStyle(.red)
        case .invalid:
            Text("The saved authorization could not be formatted.")
                .foregroundStyle(.red)
        }
    }
}

enum StoredAuthorization: Sendable {
    case json(String)
    case missing
    case unavailable
    case invalid

    static func load(accountID: UUID) -> StoredAuthorization {
        switch KeychainService.shared.lookupAccountBackup(forAccountId: accountID.uuidString, migrateLegacyStore: false) {
        case .found(let backup):
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                return .json(String(decoding: try encoder.encode(backup), as: UTF8.self))
            } catch {
                return .invalid
            }
        case .missing: return .missing
        case .storeUnavailable: return .unavailable
        }
    }
}
