import AppKit
import Foundation
import SwiftData
import OSLog

@MainActor
final class ClipboardStorageService {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Orvia", category: "persistence")
    private let modelContext: ModelContext
    private let settings: AppSettings
    private let cryptoService: LocalCryptoService

    init(modelContext: ModelContext, settings: AppSettings, cryptoService: LocalCryptoService) {
        self.modelContext = modelContext
        self.settings = settings
        self.cryptoService = cryptoService
    }

    func insert(snapshot: ClipboardSnapshot, sourceBundleID: String?) {
        do {
            try pruneExpiredItems(now: snapshot.createdAt)
            if let duplicate = try recentDuplicate(for: snapshot) {
                duplicate.createdAt = snapshot.createdAt
                duplicate.updatedAt = snapshot.createdAt
                duplicate.sourceBundleID = sourceBundleID
                try modelContext.save()
                return
            }

            let finalPayload: Data
            let encrypted: Bool
            if settings.enableEncryption {
                finalPayload = try cryptoService.encrypt(snapshot.payload)
                encrypted = true
            } else {
                finalPayload = snapshot.payload
                encrypted = false
            }

            let entity = ClipboardItemEntity(
                createdAt: snapshot.createdAt,
                updatedAt: snapshot.createdAt,
                kindRaw: snapshot.kind.rawValue,
                textSubtypeRaw: snapshot.textSubtype?.rawValue,
                payload: finalPayload,
                isEncrypted: encrypted,
                contentHash: snapshot.contentHash,
                sourceBundleID: sourceBundleID
            )

            modelContext.insert(entity)
            try enforceHistoryLimit()
            try modelContext.save()
        } catch {
            Self.logger.error("Failed to save clipboard item: \(error.localizedDescription, privacy: .public)")
        }
    }

    func fetchItems() -> [ClipboardItemEntity] {
        do {
            try pruneExpiredItems(now: Date())
            let descriptor = FetchDescriptor<ClipboardItemEntity>()
            let items = try modelContext.fetch(descriptor)
            return items.sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned {
                    return lhs.isPinned && !rhs.isPinned
                }
                if lhs.isFavorite != rhs.isFavorite {
                    return lhs.isFavorite && !rhs.isFavorite
                }
                return lhs.createdAt > rhs.createdAt
            }
        } catch {
            Self.logger.error("Failed to fetch clipboard history: \(error.localizedDescription)")
            return []
        }
    }

    func decode(_ entity: ClipboardItemEntity) -> DecodedClipboardItem? {
        let kind = ClipboardContentKind(rawValue: entity.kindRaw)
        guard let kind else { return nil }

        do {
            let rawPayload = try decryptIfNeeded(entity)
            switch kind {
            case .text:
                let text = String(data: rawPayload, encoding: .utf8)
                return DecodedClipboardItem(
                    id: entity.id,
                    createdAt: entity.createdAt,
                    kind: .text,
                    textSubtype: entity.textSubtypeRaw.flatMap(ClipboardTextSubtype.init(rawValue:)),
                    text: text,
                    image: nil,
                    isFavorite: entity.isFavorite,
                    isPinned: entity.isPinned,
                    isEncrypted: entity.isEncrypted,
                    sourceBundleID: entity.sourceBundleID,
                    sourceApplicationName: resolveApplicationName(bundleID: entity.sourceBundleID),
                    snippetName: entity.snippetName
                )
            case .image:
                let image = NSImage(data: rawPayload)
                return DecodedClipboardItem(
                    id: entity.id,
                    createdAt: entity.createdAt,
                    kind: .image,
                    textSubtype: nil,
                    text: nil,
                    image: image,
                    isFavorite: entity.isFavorite,
                    isPinned: entity.isPinned,
                    isEncrypted: entity.isEncrypted,
                    sourceBundleID: entity.sourceBundleID,
                    sourceApplicationName: resolveApplicationName(bundleID: entity.sourceBundleID),
                    snippetName: entity.snippetName
                )
            }
        } catch {
            Self.logger.error("Failed to decode clipboard item: \(error.localizedDescription)")
            return nil
        }
    }

    func toggleFavorite(itemID: UUID) {
        update(itemID: itemID) { item in
            item.isFavorite.toggle()
        }
    }

    func togglePin(itemID: UUID) {
        update(itemID: itemID) { item in
            item.isPinned.toggle()
            item.updatedAt = Date()
        }
    }

    /// Define/remove o nome de snippet. Nomes são únicos: remove o nome de outro item se já estiver em uso.
    func setSnippetName(itemID: UUID, name: String?) {
        do {
            if let name {
                let normalized = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else { return }

                let existingDescriptor = FetchDescriptor<ClipboardItemEntity>(
                    predicate: #Predicate { $0.snippetName == normalized }
                )
                for existing in try modelContext.fetch(existingDescriptor) where existing.id != itemID {
                    existing.snippetName = nil
                }

                update(itemID: itemID) { item in
                    item.snippetName = normalized
                }
            } else {
                update(itemID: itemID) { item in
                    item.snippetName = nil
                }
            }
        } catch {
            Self.logger.error("Failed to update snippet: \(error.localizedDescription)")
        }
    }

    func snippetItem(named name: String) -> ClipboardItemEntity? {
        let normalized = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        do {
            let descriptor = FetchDescriptor<ClipboardItemEntity>(
                predicate: #Predicate { $0.snippetName == normalized }
            )
            return try modelContext.fetch(descriptor).first
        } catch {
            Self.logger.error("Failed to fetch snippet: \(error.localizedDescription)")
            return nil
        }
    }

    func delete(itemID: UUID) {
        do {
            let descriptor = FetchDescriptor<ClipboardItemEntity>(predicate: #Predicate { $0.id == itemID })
            guard let found = try modelContext.fetch(descriptor).first else {
                return
            }
            modelContext.delete(found)
            try modelContext.save()
        } catch {
            Self.logger.error("Failed to delete clipboard item: \(error.localizedDescription)")
        }
    }

    func clearAll() {
        do {
            let descriptor = FetchDescriptor<ClipboardItemEntity>()
            let items = try modelContext.fetch(descriptor)
            for item in items {
                modelContext.delete(item)
            }
            try modelContext.save()
        } catch {
            Self.logger.error("Failed to clear clipboard history: \(error.localizedDescription)")
        }
    }

    private func update(itemID: UUID, block: (ClipboardItemEntity) -> Void) {
        do {
            let descriptor = FetchDescriptor<ClipboardItemEntity>(predicate: #Predicate { $0.id == itemID })
            guard let item = try modelContext.fetch(descriptor).first else {
                return
            }
            block(item)
            item.updatedAt = Date()
            try modelContext.save()
        } catch {
            Self.logger.error("Failed to update clipboard item: \(error.localizedDescription)")
        }
    }

    private func decryptIfNeeded(_ item: ClipboardItemEntity) throws -> Data {
        if item.isEncrypted {
            return try cryptoService.decrypt(item.payload)
        }
        return item.payload
    }

    private func recentDuplicate(for snapshot: ClipboardSnapshot) throws -> ClipboardItemEntity? {
        let threshold = snapshot.createdAt.addingTimeInterval(-300)
        let hash = snapshot.contentHash
        let descriptor = FetchDescriptor<ClipboardItemEntity>(
            predicate: #Predicate { $0.contentHash == hash && $0.createdAt >= threshold }
        )
        return try modelContext.fetch(descriptor).first { $0.kindRaw == snapshot.kind.rawValue }
    }

    private func enforceHistoryLimit() throws {
        let limit = settings.historyLimit
        let descriptor = FetchDescriptor<ClipboardItemEntity>()
        let allItems = try modelContext.fetch(descriptor).sorted { lhs, rhs in
            lhs.createdAt > rhs.createdAt
        }

        guard allItems.count > limit else {
            return
        }

        var overflow = allItems.count - limit
        let removable = allItems.reversed().filter { !$0.isPinned && !$0.isFavorite && $0.snippetName == nil }

        for item in removable where overflow > 0 {
            modelContext.delete(item)
            overflow -= 1
        }

        // Pinned items and snippets outlive the rolling history limit.
    }

    private func pruneExpiredItems(now: Date) throws {
        let days = settings.historyRetentionDays
        guard days > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let expired = try modelContext.fetch(FetchDescriptor<ClipboardItemEntity>())
            .filter { $0.createdAt < cutoff && !$0.isPinned && !$0.isFavorite && $0.snippetName == nil }
        guard !expired.isEmpty else { return }
        for item in expired { modelContext.delete(item) }
        try modelContext.save()
    }

    private func resolveApplicationName(bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else {
            return nil
        }

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: appURL),
           let appName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !appName.isEmpty {
            return appName
        }

        let fallback = bundleID
            .split(separator: ".")
            .last
            .map(String.init)?
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        return fallback?.capitalized
    }
}
