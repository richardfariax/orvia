import Foundation
import CryptoKit

/// Limites do scan de duplicatas: ignora arquivos minúsculos (ruído)
/// e gigantes (hash muito caro).
private let duplicateScanMinFileSize: UInt64 = 1024 * 100 // 100 KB
private let duplicateScanMaxFileSize: UInt64 = 1024 * 1024 * 1024 // 1 GB

/// Grupo de arquivos com conteúdo idêntico (mesmo hash).
struct DuplicateGroup: Identifiable {
    let hash: String
    let items: [CleanFileItem]

    var id: String { hash }
    /// Espaço recuperável mantendo uma cópia.
    var wastedBytes: UInt64 {
        guard let first = items.first else { return 0 }
        return first.bytes * UInt64(items.count - 1)
    }
}

@MainActor
final class DuplicateFinderService: ObservableObject {
    @Published private(set) var groups: [DuplicateGroup] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scannedFileCount = 0
    @Published var scanRoots: [URL]

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        scanRoots = ["Downloads", "Documents", "Desktop"].map {
            home.appendingPathComponent($0, isDirectory: true)
        }
    }

    var totalWastedBytes: UInt64 {
        groups.reduce(0) { $0 + $1.wastedBytes }
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        groups = []
        scannedFileCount = 0

        let roots = scanRoots
        Task {
            let outcome = await Task.detached(priority: .utility) { () -> (groups: [DuplicateGroup], count: Int) in
                Self.findDuplicates(in: roots)
            }.value
            groups = outcome.groups
            scannedFileCount = outcome.count
            isScanning = false
        }
    }

    /// Move os arquivos escolhidos para a Lixeira e remove-os dos grupos.
    func trash(urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        _ = FileSweeper.trash(urls: Array(urls))
        groups = groups.compactMap { group in
            let remaining = group.items.filter { !urls.contains($0.url) }
            guard remaining.count > 1 else { return nil }
            return DuplicateGroup(hash: group.hash, items: remaining)
        }
    }

    // MARK: - Busca

    nonisolated static func findDuplicates(in roots: [URL]) -> (groups: [DuplicateGroup], count: Int) {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]

        // Passo 1: agrupa por tamanho (barato).
        var bySize: [UInt64: [CleanFileItem]] = [:]
        var count = 0
        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      let size = values.fileSize.map(UInt64.init),
                      size >= duplicateScanMinFileSize, size <= duplicateScanMaxFileSize else { continue }
                count += 1
                bySize[size, default: []].append(
                    CleanFileItem(url: url, bytes: size, modifiedAt: values.contentModificationDate)
                )
            }
        }

        // Passo 2: hash SHA-256 apenas de candidatos com tamanho repetido.
        var byHash: [String: [CleanFileItem]] = [:]
        for (_, candidates) in bySize where candidates.count > 1 {
            for item in candidates {
                guard let digest = sha256(of: item.url) else { continue }
                byHash[digest, default: []].append(item)
            }
        }

        let groups = byHash
            .filter { $0.value.count > 1 }
            .map { DuplicateGroup(hash: $0.key, items: $0.value.sorted { lhs, rhs in
                (lhs.modifiedAt ?? .distantPast) > (rhs.modifiedAt ?? .distantPast)
            }) }
            .sorted { $0.wastedBytes > $1.wastedBytes }
        return (groups, count)
    }

    private nonisolated static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            guard let chunk = try? handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
