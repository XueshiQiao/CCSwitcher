import Foundation
import AppKit
import SwiftUI

@MainActor
final class UpdateChecker: ObservableObject {
    @Published var isChecking = false
    @Published var isDownloading = false
    @Published var updateAvailable = false
    @Published var latestVersion = ""
    @Published var releaseURL: URL?

    // GitHub repository details
    private let owner = "XueshiQiao"
    private let repo = "CCSwitcher"
    
    struct GitHubReleaseAsset: Codable {
        let name: String
        let browser_download_url: String
    }
    
    struct GitHubRelease: Codable {
        let tag_name: String
        let html_url: String
        let name: String?
        let body: String?
        let assets: [GitHubReleaseAsset]?
    }

    /// Checks for updates.
    /// - Parameter manual: If true, it will show an alert even if no update is found.
    func checkForUpdates(manual: Bool = false) {
        guard !isChecking && !isDownloading else { return }
        isChecking = true
        
        Task {
            defer { self.isChecking = false }
            
            do {
                let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
                var request = URLRequest(url: url)
                request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
                
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    if manual {
                        self.showAlert(title: String(localized: "Update Check Failed", bundle: L10n.bundle), message: String(localized: "Could not connect to GitHub. Please try again later.", bundle: L10n.bundle))
                    }
                    return
                }
                
                if httpResponse.statusCode == 403 || httpResponse.statusCode == 429 {
                    if manual {
                        self.showAlert(title: String(localized: "Rate Limit Exceeded", bundle: L10n.bundle), message: String(localized: "GitHub API rate limit exceeded. Please try again later.", bundle: L10n.bundle))
                    }
                    return
                } else if httpResponse.statusCode == 404 {
                    // This happens if the repository has no releases yet
                    if manual {
                        self.showAlert(title: String(localized: "Up to date", bundle: L10n.bundle), message: String(localized: "No releases found on GitHub.", bundle: L10n.bundle))
                    }
                    return
                } else if httpResponse.statusCode != 200 {
                    if manual {
                        self.showAlert(title: String(localized: "Update Check Failed", bundle: L10n.bundle), message: String(localized: "GitHub API returned status code \(httpResponse.statusCode).", bundle: L10n.bundle))
                    }
                    return
                }
                
                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                let latestTag = release.tag_name.replacingOccurrences(of: "v", with: "")
                
                // Get current app version
                guard let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
                    return
                }
                
                if self.isNewer(latest: latestTag, current: currentVersion) {
                    self.updateAvailable = true
                    self.latestVersion = latestTag
                    self.releaseURL = URL(string: release.html_url)
                    
                    // Find the DMG asset
                    let dmgAsset = release.assets?.first { $0.name.hasSuffix(".dmg") }
                    let dmgURL = dmgAsset.flatMap { URL(string: $0.browser_download_url) }
                    
                    self.promptForUpdate(version: latestTag, releaseNotes: release.body ?? "", dmgURL: dmgURL, fallbackURL: release.html_url)
                } else {
                    if manual {
                        self.showAlert(title: String(localized: "Up to date", bundle: L10n.bundle), message: String(localized: "You are running the latest version of CCSwitcher (\(currentVersion)).", bundle: L10n.bundle))
                    }
                }
            } catch {
                if manual {
                    self.showAlert(title: String(localized: "Update Check Failed", bundle: L10n.bundle), message: error.localizedDescription)
                }
            }
        }
    }
    
    private func isNewer(latest: String, current: String) -> Bool {
        let latestParts = latest.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }
        
        for i in 0..<max(latestParts.count, currentParts.count) {
            let l = i < latestParts.count ? latestParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            
            if l > c { return true }
            if l < c { return false }
        }
        
        return false
    }
    
    private func promptForUpdate(version: String, releaseNotes: String, dmgURL: URL?, fallbackURL: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "A new version of CCSwitcher is available!", bundle: L10n.bundle)
        let currentVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        alert.informativeText = String(localized: "Version \(version) is available. You are currently running version \(currentVer).\n\nWould you like to download it now?", bundle: L10n.bundle)
        alert.alertStyle = .informational

        if dmgURL != nil {
            alert.addButton(withTitle: String(localized: "Download & Install", bundle: L10n.bundle))
        } else {
            alert.addButton(withTitle: String(localized: "View Release", bundle: L10n.bundle))
        }
        alert.addButton(withTitle: String(localized: "Later", bundle: L10n.bundle))
        
        // Show alert and handle response
        if alert.runModal() == .alertFirstButtonReturn {
            if let dmgURL = dmgURL {
                Task {
                    await self.downloadAndOpen(url: dmgURL)
                }
            } else if let fallback = URL(string: fallbackURL) {
                NSWorkspace.shared.open(fallback)
            }
        }
    }
    
    private func downloadAndOpen(url: URL) async {
        self.isDownloading = true
        
        // Create a floating progress panel
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                            styleMask: [.titled, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.title = String(localized: "Downloading Update", bundle: L10n.bundle)
        panel.level = .floating
        panel.center()
        
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 15
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        
        let label = NSTextField(labelWithString: String(localized: "Downloading CCSwitcher.dmg...", bundle: L10n.bundle))
        label.font = .systemFont(ofSize: 13, weight: .medium)
        
        let indicator = NSProgressIndicator()
        indicator.isIndeterminate = true
        indicator.style = .spinning
        indicator.startAnimation(nil)
        
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(indicator)
        panel.contentView = stack
        panel.makeKeyAndOrderFront(nil)
        
        do {
            // Download the file
            let (tempURL, response) = try await URLSession.shared.download(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            
            // Move temp file to Downloads folder
            let fileManager = FileManager.default
            let downloadsDir = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            let destinationURL = downloadsDir.appendingPathComponent("CCSwitcher_Update.dmg")
            
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            
            try fileManager.moveItem(at: tempURL, to: destinationURL)
            panel.close()
            
            // Mount and open the DMG
            NSWorkspace.shared.open(destinationURL)
            
            // Prompt the user to quit so they can drag the new app to Applications
            let successAlert = NSAlert()
            successAlert.messageText = String(localized: "Download Complete", bundle: L10n.bundle)
            successAlert.informativeText = String(localized: "The update has been downloaded and opened. Please drag the new CCSwitcher to your Applications folder to replace the old one.\n\nDo you want to quit the current app now?", bundle: L10n.bundle)
            successAlert.addButton(withTitle: String(localized: "Quit CCSwitcher", bundle: L10n.bundle))
            successAlert.addButton(withTitle: String(localized: "Later", bundle: L10n.bundle))
            
            if successAlert.runModal() == .alertFirstButtonReturn {
                NSApp.terminate(nil)
            }
            
        } catch {
            panel.close()
            self.showAlert(title: String(localized: "Download Failed", bundle: L10n.bundle), message: error.localizedDescription)
        }
        
        self.isDownloading = false
    }
    
    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "OK", bundle: L10n.bundle))
        alert.runModal()
    }
}
