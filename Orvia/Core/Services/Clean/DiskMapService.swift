import Foundation

/// Nó da árvore de pastas para o mapa de disco (estilo Space Lens).
final class DiskNode: Identifiable {
    let url: URL
    let name: String
    let bytes: UInt64
    let isDirectory: Bool
    let children: [DiskNode]

    var id: URL { url }

    init(url: URL, name: String, bytes: UInt64, isDirectory: Bool, children: [DiskNode]) {
        self.url = url
        self.name = name
        self.bytes = bytes
        self.isDirectory = isDirectory
        self.children = children
    }
}

@MainActor
final class DiskMapService: ObservableObject {
    @Published private(set) var root: DiskNode?
    @Published private(set) var isScanning = false
    @Published private(set) var currentURL: URL

    init() {
        currentURL = FileManager.default.homeDirectoryForCurrentUser
    }

    func scan(url: URL? = nil) {
        guard !isScanning else { return }
        if let url { currentURL = url }
        isScanning = true
        root = nil

        let target = currentURL
        Task {
            let node = await Task.detached(priority: .utility) { () -> DiskNode in
                Self.buildTree(at: target, depth: 2)
            }.value
            root = node
            isScanning = false
        }
    }

    /// Constrói a árvore com profundidade limitada; abaixo disso agrega tamanhos.
    nonisolated static func buildTree(at url: URL, depth: Int) -> DiskNode {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        fm.fileExists(atPath: url.path, isDirectory: &isDirectory)

        guard isDirectory.boolValue else {
            return DiskNode(
                url: url,
                name: url.lastPathComponent,
                bytes: FileSweeper.allocatedSize(of: url),
                isDirectory: false,
                children: []
            )
        }

        guard depth > 0 else {
            return DiskNode(
                url: url,
                name: url.lastPathComponent,
                bytes: FileSweeper.allocatedSize(of: url),
                isDirectory: true,
                children: []
            )
        }

        let childURLs = (try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []

        let children = childURLs
            .map { buildTree(at: $0, depth: depth - 1) }
            .filter { $0.bytes > 0 }
            .sorted { $0.bytes > $1.bytes }

        let total = children.reduce(UInt64(0)) { $0 + $1.bytes }
        return DiskNode(
            url: url,
            name: url.lastPathComponent,
            bytes: total,
            isDirectory: true,
            children: children
        )
    }
}
