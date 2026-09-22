import Foundation
import AppKit

/// Item de arquivo/pasta encontrado por um scan de limpeza.
struct CleanFileItem: Identifiable, Hashable {
    let url: URL
    let bytes: UInt64
    let modifiedAt: Date?

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var path: String { url.path }
}

enum CleanFormat {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }
}

/// Utilitários de filesystem compartilhados pelos módulos de limpeza.
/// Todas as funções são síncronas e pensadas para rodar fora da main thread.
enum FileSweeper {
    /// Caminhos que jamais podem ser removidos, independentemente da regra que
    /// os produziu. Última linha de defesa contra bugs de scan.
    static func isProtected(_ url: URL) -> Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL
        let path = url.standardizedFileURL.path

        // Never traverse a symlink while estimating or removing a candidate.
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true { return true }
        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path

        let appRoot = "/Applications/"
        let isTopLevelApp = path.hasPrefix(appRoot)
            && !path.dropFirst(appRoot.count).contains("/")
            && url.pathExtension == "app"
        let tempPath = fm.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let isInHome = path.hasPrefix(home.path + "/")
        let isInTemporaryDirectory = resolvedPath.hasPrefix(tempPath + "/")
        if resolvedPath != path && !isInTemporaryDirectory { return true }
        guard isInHome || isInTemporaryDirectory || isTopLevelApp else { return true }
        if isTopLevelApp {
            if path == Bundle.main.bundleURL.standardizedFileURL.path { return true }
            return Bundle(url: url)?.bundleIdentifier?.hasPrefix("com.apple.") == true
        }

        // Nada fora da pasta pessoal (exceto o que já veio de /Applications
        // via desinstalação, que valida por conta própria).
        let protectedExact: Set<String> = [
            "/", home.path,
            home.appendingPathComponent("Desktop").path,
            home.appendingPathComponent("Documents").path,
            home.appendingPathComponent("Downloads").path,
            home.appendingPathComponent("Pictures").path,
            home.appendingPathComponent("Movies").path,
            home.appendingPathComponent("Music").path,
            home.appendingPathComponent("Applications").path,
            home.appendingPathComponent("Library").path,
            home.appendingPathComponent("Library/Application Support").path,
            home.appendingPathComponent("Library/Caches").path,
            home.appendingPathComponent("Library/Preferences").path,
            home.appendingPathComponent("Library/Logs").path,
            home.appendingPathComponent("Library/Containers").path,
            home.appendingPathComponent("Library/Mobile Documents").path,
            home.appendingPathComponent("Library/Keychains").path,
            home.appendingPathComponent(".Trash").path
        ]
        if protectedExact.contains(path) { return true }

        // Chaves e documentos do iCloud nunca são alvo de limpeza.
        let protectedPrefixes = [
            home.appendingPathComponent("Library/Keychains").path + "/",
            home.appendingPathComponent("Library/Mobile Documents").path + "/",
            home.appendingPathComponent("Library/Application Support/Orvia").path + "/"
        ]
        return protectedPrefixes.contains { path.hasPrefix($0) }
    }
    /// Tamanho total (alocado) de um arquivo ou diretório, recursivo.
    static func allocatedSize(of url: URL) -> UInt64 {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }

        if !isDirectory.boolValue {
            let values = try? url.resourceValues(forKeys: keys)
            return UInt64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            total += UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Filhos imediatos de um diretório como itens com tamanho.
    static func children(of url: URL, includeHidden: Bool = false) -> [CleanFileItem] {
        let fm = FileManager.default
        var options: FileManager.DirectoryEnumerationOptions = []
        if !includeHidden { options.insert(.skipsHiddenFiles) }
        guard let urls = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: options
        ) else { return [] }

        return urls.map { child in
            let modified = (try? child.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return CleanFileItem(url: child, bytes: allocatedSize(of: child), modifiedAt: modified)
        }
    }

    /// Move URLs para a Lixeira. Esses bytes ainda ocupam espaço no disco.
    static func trash(urls: [URL]) -> (movedToTrash: UInt64, failures: [String]) {
        let fm = FileManager.default
        var movedToTrash: UInt64 = 0
        var failures: [String] = []
        for url in urls {
            guard !isProtected(url) else {
                failures.append("\(url.lastPathComponent): caminho protegido / protected path")
                continue
            }
            let size = allocatedSize(of: url)
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
                movedToTrash += size
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (movedToTrash, failures)
    }

    /// Remove URLs permanentemente (usado apenas para conteúdo da Lixeira).
    static func removePermanently(urls: [URL]) -> (reclaimed: UInt64, failures: [String]) {
        let fm = FileManager.default
        var reclaimed: UInt64 = 0
        var failures: [String] = []
        for url in urls {
            guard !isProtected(url) else {
                failures.append("\(url.lastPathComponent): caminho protegido / protected path")
                continue
            }
            let size = allocatedSize(of: url)
            do {
                try fm.removeItem(at: url)
                reclaimed += size
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (reclaimed, failures)
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
