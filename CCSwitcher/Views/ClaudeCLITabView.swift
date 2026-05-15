import SwiftUI

/// Settings tab letting the user pick which `claude` binary CCSwitcher invokes.
struct ClaudeCLITabView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage(kClaudeBinaryPathPreferenceKey) private var preference: String = ""

    private static let autoTag = ""
    private static let customSentinel = "__custom__"

    @State private var detected: [DetectedClaudePath] = []
    @State private var selection: String = ""
    @State private var customInput: String = ""
    @State private var customError: String? = nil
    @State private var installedVersion: String? = nil
    @State private var latestVersion: String? = nil
    @State private var isLoading: Bool = false
    /// When non-nil, the next onChange callback receiving this exact value is treated as
    /// a programmatic write and suppressed. Tying the suppression to a specific value
    /// (instead of a bare bool) prevents a real user click from being eaten if SwiftUI
    /// happens to coalesce changes.
    @State private var suppressNextSelection: String? = nil
    /// Tracks the in-flight installed-version fetch so a later fetch can supersede an earlier one.
    @State private var versionLoadTask: Task<Void, Never>? = nil

    var body: some View {
        Form {
            Section("Binary path") {
                Picker("Binary", selection: $selection) {
                    Text("Auto-detect").tag(Self.autoTag)
                    Divider()
                    ForEach(detected) { item in
                        Text("\(item.label) — \(item.path)").tag(item.path)
                    }
                    Divider()
                    Text("Custom path…").tag(Self.customSentinel)
                }
                .onChange(of: selection) { _, newValue in
                    handleSelectionChange(newValue)
                }

                if selection == Self.customSentinel {
                    TextField("/absolute/path/to/claude", text: $customInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitCustomPath() }

                    if let customError {
                        Label(customError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if !customInput.isEmpty {
                        Text("Press Return to apply.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Currently using: \(ClaudeService.shared.claudePath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Section("Version") {
                HStack {
                    Text("Installed")
                    Spacer()
                    Text(installedVersion ?? (isLoading ? "Checking…" : "—"))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack {
                    Text("Latest")
                    Spacer()
                    Text(latestVersion ?? (isLoading ? "Checking…" : "—"))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if let installed = installedVersion, let latest = latestVersion, installed != latest {
                        Text("Update available")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                Button {
                    Task { await refreshAll() }
                } label: {
                    Label(isLoading ? "Refreshing…" : "Refresh detected paths & versions", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            await refreshAll()
        }
    }

    // MARK: - Loaders

    private func refreshAll() async {
        isLoading = true
        defer { isLoading = false }
        // detectedPaths() last-resorts to an interactive zsh spawn that can
        // block for up to 3 seconds (heavy .zshrc setups, iTerm integration,
        // nvm/asdf hooks). Hoist it off the MainActor so the tab renders
        // immediately and the picker fills in once the result arrives —
        // same pattern reloadVersions() already uses.
        let paths = await Task.detached(priority: .userInitiated) {
            ClaudeService.detectedPaths()
        }.value
        detected = paths
        syncSelectionToPreference()
        await reloadVersions()
    }

    /// Cancel any prior version fetch, then load installed + latest fresh.
    private func reloadVersions() async {
        versionLoadTask?.cancel()
        let activePath = ClaudeService.shared.claudePath
        let task = Task { @MainActor in
            async let installed = ClaudeService.readVersion(at: activePath)
            async let latest = ClaudeService.fetchLatestVersion()
            let i = await installed
            let l = await latest
            guard !Task.isCancelled else { return }
            installedVersion = i
            latestVersion = l
        }
        versionLoadTask = task
        await task.value
    }

    /// Set the picker's selection from the current preference. Records the expected
    /// target in `suppressNextSelection` so the resulting onChange is recognized as
    /// programmatic and skipped.
    private func syncSelectionToPreference() {
        let target: String
        if preference.isEmpty {
            target = Self.autoTag
            customInput = ""
        } else if detected.contains(where: { $0.path == preference }) {
            target = preference
            customInput = ""
        } else {
            // Preference points at a path not in the detected list — treat as custom.
            target = Self.customSentinel
            customInput = preference
        }
        guard target != selection else { return }
        suppressNextSelection = target
        selection = target
    }

    // MARK: - Selection handling

    private func handleSelectionChange(_ newValue: String) {
        // Only suppress if this onChange corresponds to the exact programmatic write
        // we made — a different newValue means a real user interaction.
        if let expected = suppressNextSelection, expected == newValue {
            suppressNextSelection = nil
            return
        }
        suppressNextSelection = nil
        customError = nil
        if newValue == Self.autoTag {
            applyPreference("")
            return
        }
        if newValue == Self.customSentinel {
            // Pre-fill custom input if preference is already a custom path.
            if customInput.isEmpty, !preference.isEmpty,
               !detected.contains(where: { $0.path == preference }) {
                customInput = preference
            }
            return
        }
        // User picked a detected path.
        applyPreference(newValue)
    }

    private func commitCustomPath() {
        let trimmed = customInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            customError = "Path is empty."
            return
        }
        guard trimmed.hasPrefix("/") else {
            customError = "Path must be absolute (start with /)."
            return
        }
        guard FileManager.default.isExecutableFile(atPath: trimmed) else {
            customError = "Not found or not executable."
            return
        }
        customError = nil
        customInput = trimmed
        applyPreference(trimmed)
        // If the entered path actually matches a detected one, prefer the detected
        // selection so the dropdown reflects it. onChange will consume the suppress token.
        if detected.contains(where: { $0.path == trimmed }), selection != trimmed {
            suppressNextSelection = trimmed
            selection = trimmed
        }
    }

    /// Write the preference, push to ClaudeService, refresh app + versions.
    /// `newValue == ""` means revert to auto.
    private func applyPreference(_ newValue: String) {
        preference = newValue
        ClaudeService.shared.setPath(newValue.isEmpty ? nil : newValue)
        Task {
            await reloadVersions()
            await appState.refresh()
        }
    }
}
