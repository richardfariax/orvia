import Foundation
import SwiftData

@Model
final class ClipboardItemEntity {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var kindRaw: String
    var textSubtypeRaw: String?
    @Attribute(.externalStorage) var payload: Data
    var isEncrypted: Bool
    var contentHash: String
    var sourceBundleID: String?
    var isFavorite: Bool
    var isPinned: Bool
    var snippetName: String?

    init(
        id: UUID = UUID(),
        createdAt: Date,
        updatedAt: Date,
        kindRaw: String,
        textSubtypeRaw: String?,
        payload: Data,
        isEncrypted: Bool,
        contentHash: String,
        sourceBundleID: String?,
        isFavorite: Bool = false,
        isPinned: Bool = false,
        snippetName: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.kindRaw = kindRaw
        self.textSubtypeRaw = textSubtypeRaw
        self.payload = payload
        self.isEncrypted = isEncrypted
        self.contentHash = contentHash
        self.sourceBundleID = sourceBundleID
        self.isFavorite = isFavorite
        self.isPinned = isPinned
        self.snippetName = snippetName
    }
}
