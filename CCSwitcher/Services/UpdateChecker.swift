import Foundation
import AppKit

@MainActor
final class UpdateChecker: ObservableObject {
    @Published var isChecking = false
    @Published var updateAvailable = false
    @Published var latestVersion = ""
    @Published var releaseURL: URL?

    // GitHub repository details
    private let owner = "XueshiQiao"
    private let repo = "CCSwitcher"
    
    struct GitHubRelease: Codable {
        let tag_name: String
        let html_url: String
        let name: String?
        let body: String?
    }

    /// Checks for updates.
    /// - Parameter manual: If true, it will show an alert even if no update is found.
    func checkForUpdates(manual: Bool = false) {
        guard !isChecking else { return }
        isChecking = true
        
        Task {
            defer { self.isChecking = false }
            
            do {
                let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
                var request = URLRequest(url: url)
                request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
                
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    if manual {
                        self.showAlert(title: "Update Check Failed", message: "Could not connect to GitHub. Please try again later.")
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
                    
                    self.promptForUpdate(version: latestTag, releaseNotes: release.body ?? "", url: release.html_url)
                } else {
                    if manual {
                        self.showAlert(title: "Up to date", message: "You are running the latest version of CCSwitcher (\(currentVersion)).")
                    }
                }
            } catch {
                if manual {
                    self.showAlert(title: "Update Check Failed", message: error.localizedDescription)
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
    
    private func promptForUpdate(version: String, releaseNotes: String, url: String) {
        let alert = NSAlert()
        alert.messageText = "A new version of CCSwitcher is available!"
        alert.informativeText = "Version \(version) is available. You are currently running version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown").\n\nWould you like to download it now?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        
        // Show alert and handle response
        if alert.runModal() == .alertFirstButtonReturn {
            if let downloadURL = URL(string: url) {
                NSWorkspace.shared.open(downloadURL)
            }
        }
    }
    
    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
