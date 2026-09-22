import Foundation
import AppKit

/// App instalado em /Applications ou ~/Applications.
struct InstalledApp: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleIdentifier: String?
    let version: String?
    let bytes: UInt64

    var id: URL { url }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
}

@MainActor
final class AppInventoryService: ObservableObject {
    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isUninstalling = false
    @Published private(set) var errorMessage: String?

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        Task {
            let loaded = await Task.detached(priority: .utility) { Self.loadApps() }.value
            apps = loaded
            isLoading = false
        }
    }

    /// Move apenas o bundle do app para a Lixeira, preservando dados e preferências.
    func uninstall(app: InstalledApp) {
        guard !isUninstalling else { return }
        guard !NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleURL?.standardizedFileURL == app.url.standardizedFileURL
        }) else {
            errorMessage = "Feche o aplicativo antes de desinstalá-lo. / Quit the app before uninstalling."
            return
        }
        isUninstalling = true
        errorMessage = nil

        Task {
            let outcome = await Task.detached(priority: .utility) {
                FileSweeper.trash(urls: [app.url])
            }.value
            if !outcome.failures.isEmpty {
                errorMessage = outcome.failures.joined(separator: "\n")
            }
            isUninstalling = false
            refresh()
        }
    }

    // MARK: - Carregamento

    nonisolated static func loadApps() -> [InstalledApp] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true)
        ]

        var found: [InstalledApp] = []
        for root in roots {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for url in urls where url.pathExtension == "app" {
                let bundle = Bundle(url: url)
                let info = bundle?.infoDictionary
                let name = (info?["CFBundleDisplayName"] as? String)
                    ?? (info?["CFBundleName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                found.append(InstalledApp(
                    url: url,
                    name: name,
                    bundleIdentifier: bundle?.bundleIdentifier,
                    version: info?["CFBundleShortVersionString"] as? String,
                    bytes: FileSweeper.allocatedSize(of: url)
                ))
            }
        }
        return found.sorted { $0.bytes > $1.bytes }
    }

}
