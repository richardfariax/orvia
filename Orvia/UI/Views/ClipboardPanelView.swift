import SwiftUI

struct ClipboardPanelView: View {
    @ObservedObject var viewModel: ClipboardPanelViewModel
    @ObservedObject var settings: AppSettings
    var embedded = false
    let closePanel: () -> Void
    let onPasteItem: ((DecodedClipboardItem) -> Void)?

    init(
        viewModel: ClipboardPanelViewModel,
        settings: AppSettings,
        embedded: Bool = false,
        onPasteItem: ((DecodedClipboardItem) -> Void)? = nil,
        closePanel: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.settings = settings
        self.embedded = embedded
        self.onPasteItem = onPasteItem
        self.closePanel = closePanel
    }

    var body: some View {
        Group {
            if embedded {
                panelContent
                    .padding(16)
                    .frame(maxWidth: 640, maxHeight: .infinity)
                    .orviaSettingsSurface(cornerRadius: 14)
                    .padding(24)
            } else {
                GlassEffectContainer {
                    panelContent
                        .padding(16)
                        .glassEffect(.regular, in: .rect(cornerRadius: 14))
                }
                .frame(width: 560, height: 700)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: viewModel.searchText)
        .animation(.easeInOut(duration: 0.16), value: viewModel.selectedItemID)
        .onAppear {
            viewModel.refresh()
        }
    }

    private var panelContent: some View {
        VStack(spacing: 12) {
            header
            searchField
            filterBar
            content
            keyboardHelp
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 10) {
                BrandLogoView(size: 24, cornerRadius: 6)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Orvia")
                        .font(.title3.weight(.semibold))
                    Text("\(settings.hotkeyDisplay) · \(t("Enter para colar", "Press Enter to paste"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            if !viewModel.pasteStack.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.caption2)
                    Text("\(viewModel.pasteStack.count)")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                .foregroundStyle(Color.accentColor)
                .help(t("Itens na pilha de colagem", "Items in paste stack"))
            }

            Text(displayedCountText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(t("Limpar", "Clear")) {
                viewModel.clearAll()
            }
            .buttonStyle(.bordered)

            Button {
                closePanel()
            } label: {
                Image(systemName: "xmark")
                    .font(.callout.weight(.semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
        }
    }

    private var searchField: some View {
        TextField(t("Buscar por conteúdo ou app", "Search by content or app"), text: $viewModel.searchText)
            .textFieldStyle(.roundedBorder)
            .onSubmit {
                if let item = viewModel.selectedItem {
                    paste(item)
                }
            }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Text(t("Filtro", "Filter"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("", selection: filterBinding) {
                ForEach(ClipboardPanelFilter.allCases) { filter in
                    Text(filter.title(for: settings.language)).tag(filter)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            Spacer(minLength: 0)

            if viewModel.activeFilter != .all {
                Button(t("Limpar filtro", "Clear filter")) {
                    viewModel.setFilter(.all)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    private var content: some View {
        GroupBox {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.items) { item in
                            ClipboardCardView(
                                item: item,
                                isSelected: viewModel.selectedItemID == item.id,
                                language: settings.language,
                                onPaste: {
                                    paste(item)
                                },
                                onSelect: {
                                    viewModel.select(itemID: item.id)
                                },
                                onToggleFavorite: {
                                    viewModel.toggleFavorite(itemID: item.id)
                                },
                                onTogglePin: {
                                    viewModel.togglePin(itemID: item.id)
                                },
                                onDelete: {
                                    viewModel.delete(itemID: item.id)
                                },
                                onTransform: { transform in
                                    _ = viewModel.transformAndCopy(item: item, transform: transform)
                                },
                                onSaveSnippet: {
                                    promptSnippetName(for: item)
                                },
                                onRemoveSnippet: {
                                    viewModel.removeSnippet(itemID: item.id)
                                },
                                onAddToStack: {
                                    viewModel.addToStack(itemID: item.id)
                                }
                            )
                            .id(item.id)
                        }

                        if viewModel.items.isEmpty {
                            emptyState
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .onChange(of: viewModel.selectedItemID, initial: false) { _, selectedItemID in
                    guard let selectedItemID else { return }
                    withAnimation(.easeInOut(duration: 0.14)) {
                        proxy.scrollTo(selectedItemID, anchor: .center)
                    }
                }
            }
        }
        .groupBoxStyle(.automatic)
    }

    private var keyboardHelp: some View {
        HStack(spacing: 10) {
            Text("⌘1-6")
            Text("⌘S")
            Text("⌘D")
            Text("⌘P")
            Text("⌘C")
            Text("↑ ↓")
            Text("↩")
            Spacer(minLength: 0)
            Text(t("atalhos", "shortcuts"))
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
            Text(t("Nenhum item no histórico", "No history items"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(t("Copie algo para começar", "Copy something to start"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }

    private func t(_ pt: String, _ en: String) -> String {
        settings.text(ptBR: pt, en: en)
    }

    private func paste(_ item: DecodedClipboardItem) {
        if let onPasteItem {
            onPasteItem(item)
        } else {
            closePanel()
            viewModel.paste(item: item)
        }
    }

    private func promptSnippetName(for item: DecodedClipboardItem) {
        let alert = NSAlert()
        alert.messageText = t("Salvar como snippet", "Save as snippet")
        alert.informativeText = t(
            "Dê um nome curto. Você poderá colar por voz: \"cole o snippet <nome>\".",
            "Choose a short name. You can paste it by voice: \"paste snippet <name>\"."
        )
        alert.addButton(withTitle: t("Salvar", "Save"))
        alert.addButton(withTitle: t("Cancelar", "Cancel"))

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.placeholderString = t("nome do snippet", "snippet name")
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        viewModel.saveSnippet(named: name, itemID: item.id)
    }

    private var displayedCountText: String {
        let total = viewModel.itemCount(for: .all)
        let filtered = viewModel.items.count
        if filtered == total {
            return "\(total) \(t("itens", "items"))"
        }
        return "\(filtered)/\(total) \(t("itens", "items"))"
    }

    private var filterBinding: Binding<ClipboardPanelFilter> {
        Binding(
            get: { viewModel.activeFilter },
            set: { viewModel.setFilter($0) }
        )
    }
}
