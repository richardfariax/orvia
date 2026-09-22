import SwiftUI

struct ClipboardCardView: View {
    let item: DecodedClipboardItem
    let isSelected: Bool
    let language: AppLanguage
    let onPaste: () -> Void
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void
    let onTransform: (ClipboardTextTransform) -> Void
    let onSaveSnippet: () -> Void
    let onRemoveSnippet: () -> Void
    let onAddToStack: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: leadingIconName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                Text(titleText)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Spacer(minLength: 6)

                if let snippetName = item.snippetName {
                    Text(snippetName)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                }

                if item.isEncrypted {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                actionButtons
            }

            contentView
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))

                if let sourceApplicationName = item.sourceApplicationName {
                    Text("•")
                    Text(sourceApplicationName)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(rowBackground)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            onSelect()
            onPaste()
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .contextMenu {
            contextMenuContent
        }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selectionColor)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(isSelected ? 0.9 : 0.45), lineWidth: 1)
            )
    }

    private var selectionColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.20)
        }
        if isHovering {
            return Color(nsColor: .controlAccentColor).opacity(0.08)
        }
        return Color(nsColor: .controlBackgroundColor).opacity(0.35)
    }

    @ViewBuilder
    private var contentView: some View {
        switch item.kind {
        case .text:
            Text(item.text ?? t("Conteúdo indisponível", "Unavailable content"))
                .font(.footnote)
                .lineLimit(3)
                .foregroundStyle(.primary)
        case .image:
            if let image = item.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Text(t("Imagem indisponível", "Unavailable image"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 6) {
            iconActionButton(
                systemImage: item.isFavorite ? "star.fill" : "star",
                label: t("Favoritar", "Favorite"),
                tint: .yellow,
                action: onToggleFavorite
            )

            iconActionButton(
                systemImage: item.isPinned ? "pin.fill" : "pin",
                label: t("Fixar", "Pin"),
                tint: .secondary,
                action: onTogglePin
            )

            iconActionButton(
                systemImage: "trash",
                label: t("Excluir", "Delete"),
                tint: .red,
                action: onDelete
            )
        }
        .opacity(isHovering || isSelected ? 1 : 0.72)
    }

    private func iconActionButton(
        systemImage: String,
        label: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .help(label)
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        if item.kind == .text {
            Menu(t("Transformar e copiar", "Transform & copy")) {
                ForEach(ClipboardTextTransform.allCases) { transform in
                    Button(transform.title(for: language)) {
                        onTransform(transform)
                    }
                }
            }

            Divider()
        }

        if item.snippetName == nil {
            Button(t("Salvar como snippet...", "Save as snippet...")) {
                onSaveSnippet()
            }
        } else {
            Button(t("Remover snippet", "Remove snippet")) {
                onRemoveSnippet()
            }
        }

        Button(t("Adicionar à pilha de colagem", "Add to paste stack")) {
            onAddToStack()
        }

        Divider()

        Button(t("Excluir", "Delete"), role: .destructive) {
            onDelete()
        }
    }

    private var leadingIconName: String {
        switch item.kind {
        case .text:
            switch item.textSubtype {
            case .url:
                return "link"
            case .email:
                return "envelope"
            case .code:
                return "chevron.left.forwardslash.chevron.right"
            case .longText:
                return "doc.text"
            case .json:
                return "curlybraces"
            case .color:
                return "paintpalette"
            case .hash:
                return "number"
            case .plain, .none:
                return "text.alignleft"
            }
        case .image:
            return "photo"
        }
    }

    private var titleText: String {
        switch item.kind {
        case .text:
            return item.text ?? t("Texto indisponível", "Unavailable text")
        case .image:
            return t("Imagem copiada", "Copied image")
        }
    }

    private func t(_ pt: String, _ en: String) -> String {
        language.text(ptBR: pt, en: en)
    }
}
