import AppKit
import Foundation

enum ClipboardContentKind: String, Codable {
    case text
    case image
}

enum ClipboardTextSubtype: String, Codable {
    case plain
    case url
    case email
    case code
    case longText
    case json
    case color
    case hash
}

struct ClipboardSnapshot {
    let kind: ClipboardContentKind
    let textSubtype: ClipboardTextSubtype?
    let payload: Data
    let contentHash: String
    let createdAt: Date
}

struct DecodedClipboardItem: Identifiable {
    let id: UUID
    let createdAt: Date
    let kind: ClipboardContentKind
    let textSubtype: ClipboardTextSubtype?
    let text: String?
    let image: NSImage?
    let isFavorite: Bool
    let isPinned: Bool
    let isEncrypted: Bool
    let sourceBundleID: String?
    let sourceApplicationName: String?
    let snippetName: String?
}
