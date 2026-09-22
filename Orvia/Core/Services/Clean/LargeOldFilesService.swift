import Foundation

@MainActor
final class LargeOldFilesService: ObservableObject {
    enum SizeThreshold: UInt64, CaseIterable, Identifiable {
        case mb50 = 52_428_800
        case mb100 = 104_857_600
        case mb500 = 524_288_000
        case gb1 = 1_073_741_824

        var id: UInt64 { rawValue }
        var label: String { CleanFormat.bytes(rawValue) }
    }

    @Published private(set) var files: [CleanFileItem] = []
    @Published private(set) var isScanning = false
    @Published private(set) var errorMessage: String?
    @Published var threshold: SizeThreshold = .mb100

    var totalBytes: UInt64 {
        files.reduce(0) { $0 + $1.bytes }
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        files = []
        errorMessage = nil

        let minSize = threshold.rawValue
        Task {
            let found = await Task.detached(priority: .utility) { () -> [CleanFileItem] in
                Self.findLargeFiles(minSize: minSize)
            }.value
            files = found
            isScanning = false
        }
    }

    func trash(urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        let outcome = FileSweeper.trash(urls: Array(urls))
        errorMessage = outcome.failures.isEmpty ? nil : outcome.failures.joined(separator: "\n")
        files.removeAll { urls.contains($0.url) && !FileManager.default.fileExists(atPath: $0.url.path) }
    }

    nonisolated static func findLargeFiles(minSize: UInt64, limit: Int = 300) -> [CleanFileItem] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        // Library fica de fora: caches são cobertos pelo módulo de limpeza.
        let skipped = home.appendingPathComponent("Library", isDirectory: true).path

        guard let enumerator = fm.enumerator(
            at: home,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var found: [CleanFileItem] = []
        for case let url as URL in enumerator {
            if url.path.hasPrefix(skipped) {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let size = values.fileSize.map(UInt64.init),
                  size >= minSize else { continue }
            found.append(CleanFileItem(url: url, bytes: size, modifiedAt: values.contentModificationDate))
        }
        return Array(found.sorted { $0.bytes > $1.bytes }.prefix(limit))
    }
}
