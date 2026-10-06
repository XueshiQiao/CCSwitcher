import SwiftUI

struct CopyEmailButton: View {
    let email: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(email, forType: .string)
        } label: {
            Label(copied ? "Email copied" : "Copy full email", systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.plain)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .help(copied ? "Email copied" : "Copy full email")
        .onChange(of: email) { _, _ in copied = false }
    }
}
