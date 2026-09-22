import AppKit
import Combine
import Foundation

enum ClipboardPanelFilter: String, CaseIterable, Identifiable {
    case all
    case favorites
    case pinned
    case textOnly
    case imagesOnly
    case snippets

    var id: String { rawValue }

    func title(for language: AppLanguage) -> String {
        switch self {
        case .all:
            return language.text(ptBR: "Todos", en: "All")
        case .favorites:
            return language.text(ptBR: "Favoritos", en: "Favorites")
        case .pinned:
            return language.text(ptBR: "Fixados", en: "Pinned")
        case .textOnly:
            return language.text(ptBR: "Textos", en: "Text")
        case .imagesOnly:
            return language.text(ptBR: "Imagens", en: "Images")
        case .snippets:
            return "Snippets"
        }
    }

    func matches(_ item: DecodedClipboardItem) -> Bool {
        switch self {
        case .all:
            return true
        case .favorites:
            return item.isFavorite
        case .pinned:
            return item.isPinned
        case .textOnly:
            return item.kind == .text
        case .imagesOnly:
            return item.kind == .image
        case .snippets:
            return item.snippetName != nil
        }
    }
}

@MainActor
final class ClipboardPanelViewModel: ObservableObject {
    @Published var searchText: String = "" {
        didSet { applyFiltering() }
    }
    @Published private(set) var activeFilter: ClipboardPanelFilter = .all {
        didSet { applyFiltering() }
    }
    @Published private(set) var items: [DecodedClipboardItem] = []
    @Published private(set) var selectedItemID: UUID?
    @Published private(set) var pasteStack: [UUID] = []

    private let storageService: ClipboardStorageService
    private let pasteService: PasteService
    private let targetApplicationProvider: () -> NSRunningApplication?
    private var allItems: [DecodedClipboardItem] = []

    init(
        storageService: ClipboardStorageService,
        pasteService: PasteService,
        targetApplicationProvider: @escaping () -> NSRunningApplication?
    ) {
        self.storageService = storageService
        self.pasteService = pasteService
        self.targetApplicationProvider = targetApplicationProvider

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleClipboardUpdate),
            name: .clipboardDidUpdate,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func refresh() {
        let entities = storageService.fetchItems()
        allItems = entities.compactMap(storageService.decode)
        applyFiltering()
    }

    func select(itemID: UUID) {
        selectedItemID = itemID
    }

    func setFilter(_ filter: ClipboardPanelFilter) {
        activeFilter = filter
    }

    func itemCount(for filter: ClipboardPanelFilter) -> Int {
        allItems.filter(filter.matches).count
    }

    func moveSelection(upward: Bool) {
        guard !items.isEmpty else {
            selectedItemID = nil
            return
        }

        guard let selectedItemID,
              let currentIndex = items.firstIndex(where: { $0.id == selectedItemID }) else {
            selectedItemID = items.first?.id
            return
        }

        let nextIndex: Int
        if upward {
            nextIndex = max(currentIndex - 1, 0)
        } else {
            nextIndex = min(currentIndex + 1, items.count - 1)
        }
        self.selectedItemID = items[nextIndex].id
    }

    func paste(item: DecodedClipboardItem, targetApplication: NSRunningApplication? = nil) {
        selectedItemID = item.id
        pasteService.paste(item: item, targetApplication: targetApplication ?? targetApplicationProvider())
    }

    func pasteSelectedItem(targetApplication: NSRunningApplication? = nil) {
        guard let selectedItemID,
              let selected = items.first(where: { $0.id == selectedItemID }) else {
            return
        }
        paste(item: selected, targetApplication: targetApplication)
    }

    @discardableResult
    func copySelectedItemToPasteboard() -> Bool {
        guard let selectedItem = selectedItem else {
            return false
        }
        return copyToPasteboard(item: selectedItem)
    }

    @discardableResult
    func copyToPasteboard(item: DecodedClipboardItem) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.kind {
        case .text:
            guard let text = item.text else {
                return false
            }
            pasteboard.setString(text, forType: .string)
        case .image:
            guard let image = item.image else {
                return false
            }
            pasteboard.writeObjects([image])
        }

        NotificationCenter.default.post(name: .clipboardDidProgrammaticWrite, object: nil)
        return true
    }

    // MARK: - Acesso por índice/recência (comandos de voz)

    /// Item na posição exibida (1-based), na mesma ordem do painel sem filtro.
    func item(atDisplayIndex index: Int) -> DecodedClipboardItem? {
        guard index >= 1, index <= allItems.count else { return nil }
        return allItems[index - 1]
    }

    /// Item mais recente por data de cópia (ignora ordenação de pin/favorito).
    func mostRecentItem() -> DecodedClipboardItem? {
        allItems.max { $0.createdAt < $1.createdAt }
    }

    var itemCount: Int { allItems.count }

    func snippetNames() -> [String] {
        allItems.compactMap(\.snippetName).sorted()
    }

    @discardableResult
    func transformMostRecent(_ transform: ClipboardTextTransform) -> Bool {
        guard let item = mostRecentItem() else { return false }
        return transformAndCopy(item: item, transform: transform)
    }

    // MARK: - Transformações de texto

    /// Aplica a transformação e copia o resultado para o clipboard.
    /// O monitor registra o resultado como novo item do histórico.
    @discardableResult
    func transformAndCopy(item: DecodedClipboardItem, transform: ClipboardTextTransform) -> Bool {
        guard item.kind == .text, let text = item.text,
              let result = TextTransformer.apply(transform, to: text) else {
            return false
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(result, forType: .string)
        // Sem post de .clipboardDidProgrammaticWrite: o monitor deve salvar o resultado.
        return true
    }

    @discardableResult
    func formatMostRecentJSON() -> Bool {
        guard let item = allItems
            .filter({ $0.kind == .text })
            .max(by: { $0.createdAt < $1.createdAt }) else {
            return false
        }
        return transformAndCopy(item: item, transform: .prettyJSON)
    }

    // MARK: - Snippets

    func saveSnippet(named name: String, itemID: UUID) {
        storageService.setSnippetName(itemID: itemID, name: name)
        refresh()
    }

    func removeSnippet(itemID: UUID) {
        storageService.setSnippetName(itemID: itemID, name: nil)
        refresh()
    }

    @discardableResult
    func saveMostRecentAsSnippet(named name: String) -> Bool {
        guard let item = mostRecentItem() else { return false }
        saveSnippet(named: name, itemID: item.id)
        return true
    }

    func snippet(named name: String) -> DecodedClipboardItem? {
        guard let entity = storageService.snippetItem(named: name) else { return nil }
        return storageService.decode(entity)
    }

    // MARK: - Paste stack

    func addToStack(itemID: UUID) {
        guard !pasteStack.contains(itemID) else { return }
        pasteStack.append(itemID)
    }

    func addSelectedToStack() {
        guard let selectedItemID else { return }
        addToStack(itemID: selectedItemID)
    }

    @discardableResult
    func pasteNextFromStack(targetApplication: NSRunningApplication? = nil) -> Bool {
        refresh()
        while !pasteStack.isEmpty {
            let nextID = pasteStack.removeFirst()
            if let item = allItems.first(where: { $0.id == nextID }) {
                paste(item: item, targetApplication: targetApplication)
                return true
            }
        }
        return false
    }

    func clearStack() {
        pasteStack.removeAll()
    }

    func toggleFavorite(itemID: UUID) {
        storageService.toggleFavorite(itemID: itemID)
        refresh()
    }

    func toggleFavoriteForSelectedItem() {
        guard let selectedItemID else { return }
        toggleFavorite(itemID: selectedItemID)
    }

    func togglePin(itemID: UUID) {
        storageService.togglePin(itemID: itemID)
        refresh()
    }

    func togglePinForSelectedItem() {
        guard let selectedItemID else { return }
        togglePin(itemID: selectedItemID)
    }

    func delete(itemID: UUID) {
        storageService.delete(itemID: itemID)
        refresh()
    }

    func clearAll() {
        storageService.clearAll()
        refresh()
    }

    @objc private func handleClipboardUpdate() {
        refresh()
    }

    private func applyFiltering() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            items = allItems.filter(activeFilter.matches)
            ensureValidSelection()
            return
        }

        let lowercasedQuery = query.lowercased()
        items = allItems.filter { item in
            guard activeFilter.matches(item) else {
                return false
            }

            if let text = item.text?.lowercased(), text.contains(lowercasedQuery) {
                return true
            }

            if let sourceBundleID = item.sourceBundleID?.lowercased(), sourceBundleID.contains(lowercasedQuery) {
                return true
            }

            if let snippetName = item.snippetName, snippetName.contains(lowercasedQuery) {
                return true
            }

            return false
        }
        ensureValidSelection()
    }

    private func ensureValidSelection() {
        if items.isEmpty {
            selectedItemID = nil
            return
        }

        if let selectedItemID,
           items.contains(where: { $0.id == selectedItemID }) {
            return
        }

        self.selectedItemID = items.first?.id
    }

    private var selectedItem: DecodedClipboardItem? {
        guard let selectedItemID else {
            return nil
        }

        return items.first(where: { $0.id == selectedItemID })
    }
}
