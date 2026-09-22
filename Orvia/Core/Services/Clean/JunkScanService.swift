import Foundation

/// Resultado do scan de uma regra de limpeza.
struct CleanupRuleResult {
    let ruleID: String
    let items: [CleanFileItem]
    var bytes: UInt64 { items.reduce(0) { $0 + $1.bytes } }
}

struct JunkCleanupSummary: Equatable {
    let reclaimedBytes: UInt64
    let movedToTrashBytes: UInt64
    let failures: [String]
}

/// Motor de limpeza baseado no catálogo de regras curadas.
@MainActor
final class JunkScanService: ObservableObject {
    let rules = CleanupRuleCatalog.rules()

    @Published private(set) var results: [String: CleanupRuleResult] = [:]
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published private(set) var lastCleanup: JunkCleanupSummary?
    /// Total liberado pelo Orvia desde a instalação (persistido).
    @Published private(set) var lifetimeReclaimedBytes: UInt64

    private static let lifetimeKey = "orvia.lifetimeVerifiedReclaimedBytes"

    init() {
        let stored = UserDefaults.standard.object(forKey: Self.lifetimeKey) as? NSNumber
        lifetimeReclaimedBytes = stored?.uint64Value ?? 0
    }

    var totalBytes: UInt64 {
        results.values.reduce(0) { $0 + $1.bytes }
    }

    /// Regras seguras e pré-selecionadas — usadas na limpeza de 1 clique.
    var safeDefaultRuleIDs: Set<String> {
        Set(rules.filter { $0.safety == .safe && $0.selectedByDefault }.map(\.id))
    }

    /// Bytes recuperáveis apenas pelas regras seguras.
    var safeBytes: UInt64 {
        safeDefaultRuleIDs.reduce(0) { $0 + bytes(forRule: $1) }
    }

    func bytes(forRule id: String) -> UInt64 {
        results[id]?.bytes ?? 0
    }

    func itemCount(forRule id: String) -> Int {
        results[id]?.items.count ?? 0
    }

    func rule(withID id: String) -> CleanupRule? {
        rules.first { $0.id == id }
    }

    func scan(completion: (() -> Void)? = nil) {
        guard !isScanning, !isCleaning else { return }
        isScanning = true

        let rules = self.rules
        Task {
            let scanned = await Task.detached(priority: .utility) { () -> [CleanupRuleResult] in
                rules.map(Self.scanRule)
            }.value
            results = Dictionary(uniqueKeysWithValues: scanned.map { ($0.ruleID, $0) })
            isScanning = false
            completion?()
        }
    }

    /// Limpa as regras selecionadas. Tudo vai para a Lixeira, exceto regras
    /// marcadas como permanentes (apenas a própria Lixeira).
    func clean(ruleIDs: Set<String>, completion: (() -> Void)? = nil) {
        guard !ruleIDs.isEmpty, !isScanning, !isCleaning else { return }
        isCleaning = true

        let snapshot = results
        let rulesByID = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        Task {
            let summary = await Task.detached(priority: .utility) { () -> JunkCleanupSummary in
                var reclaimed: UInt64 = 0
                var movedToTrash: UInt64 = 0
                var failures: [String] = []
                for id in ruleIDs {
                    guard let result = snapshot[id], let rule = rulesByID[id] else { continue }
                    guard rule.safety == .safe else {
                        failures.append("\(rule.titleEN): review required")
                        continue
                    }
                    let urls = result.items.map(\.url).filter { !FileSweeper.isProtected($0) }
                    if rule.deletesPermanently {
                        let outcome = FileSweeper.removePermanently(urls: urls)
                        reclaimed += outcome.reclaimed
                        failures.append(contentsOf: outcome.failures)
                    } else {
                        let outcome = FileSweeper.trash(urls: urls)
                        movedToTrash += outcome.movedToTrash
                        failures.append(contentsOf: outcome.failures)
                    }
                }
                return JunkCleanupSummary(reclaimedBytes: reclaimed, movedToTrashBytes: movedToTrash, failures: failures)
            }.value
            lastCleanup = summary
            lifetimeReclaimedBytes += summary.reclaimedBytes
            UserDefaults.standard.set(NSNumber(value: lifetimeReclaimedBytes), forKey: Self.lifetimeKey)
            isCleaning = false
            scan(completion: completion)
        }
    }

    /// Limpa itens selecionados individualmente, agrupados por regra
    /// (usado pelo Gerenciador de Limpeza com seleção por item).
    func clean(itemsByRule: [String: Set<URL>], completion: (() -> Void)? = nil) {
        let nonEmpty = itemsByRule.filter { !$0.value.isEmpty }
        guard !nonEmpty.isEmpty, !isScanning, !isCleaning else { return }
        isCleaning = true

        let rulesByID = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        let scannedResults = results
        Task {
            let summary = await Task.detached(priority: .utility) { () -> JunkCleanupSummary in
                var reclaimed: UInt64 = 0
                var movedToTrash: UInt64 = 0
                var failures: [String] = []
                for (ruleID, urls) in nonEmpty {
                    guard let rule = rulesByID[ruleID], let scanned = scannedResults[ruleID] else { continue }
                    let allowed = Set(scanned.items.map(\.url))
                    let validatedURLs = urls.filter { allowed.contains($0) && !FileSweeper.isProtected($0) }
                    if validatedURLs.count != urls.count {
                        failures.append("\(rule.titleEN): invalid selection")
                    }
                    if rule.deletesPermanently {
                        let outcome = FileSweeper.removePermanently(urls: Array(validatedURLs))
                        reclaimed += outcome.reclaimed
                        failures.append(contentsOf: outcome.failures)
                    } else {
                        let outcome = FileSweeper.trash(urls: Array(validatedURLs))
                        movedToTrash += outcome.movedToTrash
                        failures.append(contentsOf: outcome.failures)
                    }
                }
                return JunkCleanupSummary(reclaimedBytes: reclaimed, movedToTrashBytes: movedToTrash, failures: failures)
            }.value
            lastCleanup = summary
            lifetimeReclaimedBytes += summary.reclaimedBytes
            UserDefaults.standard.set(NSNumber(value: lifetimeReclaimedBytes), forKey: Self.lifetimeKey)
            isCleaning = false
            scan(completion: completion)
        }
    }

    /// Remove um item individual de uma regra (usado no gerenciador de revisão).
    func trashSingleItem(ruleID: String, url: URL) {
        guard let result = results[ruleID], let rule = rule(withID: ruleID) else { return }
        guard result.items.contains(where: { $0.url == url }), !FileSweeper.isProtected(url) else { return }
        let failures: [String]
        let reclaimed: UInt64
        if rule.deletesPermanently {
            let outcome = FileSweeper.removePermanently(urls: [url])
            failures = outcome.failures
            reclaimed = outcome.reclaimed
        } else {
            failures = FileSweeper.trash(urls: [url]).failures
            reclaimed = 0
        }
        guard failures.isEmpty else { return }
        results[ruleID] = CleanupRuleResult(
            ruleID: ruleID,
            items: result.items.filter { $0.url != url }
        )
        lifetimeReclaimedBytes += reclaimed
        UserDefaults.standard.set(NSNumber(value: lifetimeReclaimedBytes), forKey: Self.lifetimeKey)
    }

    /// Bytes das regras seguras de uma seção (para o botão "Limpar" dos cards).
    func safeBytes(in section: CleanupSection) -> UInt64 {
        rules
            .filter { $0.section == section && $0.safety == .safe && $0.selectedByDefault }
            .reduce(0) { $0 + bytes(forRule: $1.id) }
    }

    func safeRuleIDs(in section: CleanupSection) -> Set<String> {
        Set(rules
            .filter { $0.section == section && $0.safety == .safe && $0.selectedByDefault }
            .map(\.id))
    }

    func bytes(in section: CleanupSection) -> UInt64 {
        rules.filter { $0.section == section }.reduce(0) { $0 + bytes(forRule: $1.id) }
    }

    // MARK: - Scan

    nonisolated static func scanRule(_ rule: CleanupRule) -> CleanupRuleResult {
        let fm = FileManager.default
        var items: [CleanFileItem] = []
        let cutoff = rule.minAgeDays.map { Date().addingTimeInterval(-Double($0) * 86_400) }

        for root in rule.roots {
            guard fm.fileExists(atPath: root.path) else { continue }
            switch rule.mode {
            case .wholeFolder:
                let size = FileSweeper.allocatedSize(of: root)
                if size > 0 {
                    items.append(CleanFileItem(url: root, bytes: size, modifiedAt: nil))
                }
            case .children:
                var children = FileSweeper.children(of: root, includeHidden: rule.includeHidden)
                if !rule.excludedFirstComponents.isEmpty {
                    children.removeAll { rule.excludedFirstComponents.contains($0.url.lastPathComponent) }
                }
                if let cutoff {
                    children.removeAll { item in
                        guard let modified = item.modifiedAt else { return true }
                        return modified >= cutoff
                    }
                }
                items += children
            case .filesWithExtensions(let extensions):
                let children = FileSweeper.children(of: root, includeHidden: rule.includeHidden)
                items += children.filter { item in
                    guard extensions.contains(item.url.pathExtension.lowercased()) else { return false }
                    guard let cutoff else { return true }
                    guard let modified = item.modifiedAt else { return false }
                    return modified < cutoff
                }
            }
        }

        let filtered = items.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        return CleanupRuleResult(ruleID: rule.id, items: filtered)
    }
}
