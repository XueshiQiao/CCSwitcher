import SwiftUI

/// Settings editor for the menu-bar modules: a reorderable list of all
/// available modules with a toggle per row, plus a live preview showing
/// exactly what will appear in the menu bar.
struct MenuBarModulesSettingsView: View {
    @AppStorage("showFullEmail") private var showFullEmail = false
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var config: MenuBarConfig

    @State private var rows: [Row] = []
    @State private var tick: Date = Date()
    private let previewTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Menu bar modules", bundle: L10n.bundle))
                .font(.subheadline.weight(.semibold))

            Text(String(localized: "Drag to reorder, toggle to enable. Disabled modules sit at the bottom.", bundle: L10n.bundle))
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach($rows) { $row in
                    HStack(spacing: 10) {
                        Toggle("", isOn: $row.isEnabled)
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                        Text(row.module.localizedDisplayName)
                            .font(.callout)
                        Spacer(minLength: 8)
                        MenuBarModuleView(
                            module: row.module,
                            appState: appState,
                            showFullEmail: showFullEmail,
                            tick: tick
                        )
                        .opacity(row.isEnabled ? 1.0 : 0.35)
                    }
                    .padding(.vertical, 2)
                }
                .onMove { from, to in
                    rows.move(fromOffsets: from, toOffset: to)
                    // `.onChange` below catches the persist; no explicit call here.
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 220)
            .onChange(of: rows.map { "\($0.module.rawValue)|\($0.isEnabled)" }) { _, _ in
                persist()
            }

            Label(
                String(localized: "The vertical line marks time elapsed in the window; fill past it means you're using faster than the clock.", bundle: L10n.bundle),
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 2)

            Divider()

            HStack(spacing: 8) {
                Text(String(localized: "Preview", bundle: L10n.bundle))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                previewBar
            }
            .padding(.top, 2)
        }
        .onAppear(perform: load)
        .onReceive(previewTimer) { tick = $0 }
    }

    // MARK: - Preview

    private var previewBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 13))
            ForEach(rows.filter(\.isEnabled)) { row in
                MenuBarModuleView(
                    module: row.module,
                    appState: appState,
                    showFullEmail: showFullEmail,
                    tick: tick
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .underPageBackgroundColor))
        )
    }

    // MARK: - State helpers

    private func load() {
        let enabled = config.modules
        let enabledSet = Set(enabled)

        // Enabled modules first, in user order; then any remaining (disabled).
        var ordered: [Row] = enabled.map { Row(module: $0, isEnabled: true) }
        for module in MenuBarModule.allCases where !enabledSet.contains(module) {
            ordered.append(Row(module: module, isEnabled: false))
        }
        rows = ordered
    }

    private func persist() {
        config.set(rows.filter(\.isEnabled).map(\.module))
    }

    // MARK: - Row

    fileprivate struct Row: Identifiable, Equatable {
        let module: MenuBarModule
        var isEnabled: Bool
        var id: String { module.rawValue }
    }
}
