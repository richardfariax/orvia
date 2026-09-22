import SwiftUI

/// Cleanup, storage review, and startup live in one native workspace.
struct CleanCenterView: View {
    private enum Area: String, CaseIterable, Identifiable {
        case cleanup, storage, apps
        var id: String { rawValue }
    }

    @ObservedObject var settings: AppSettings
    @ObservedObject var metrics: SystemMetricsService

    @StateObject private var junk = JunkScanService()
    @StateObject private var largeFiles = LargeOldFilesService()
    @StateObject private var duplicates = DuplicateFinderService()
    @StateObject private var diskMap = DiskMapService()
    @StateObject private var apps = AppInventoryService()
    @StateObject private var startup = StartupItemsService()

    @State private var area: Area = .cleanup
    @State private var selectedRule: CleanupRule?
    @State private var selectedURLs: Set<URL> = []
    @State private var cleanupPending: [String: Set<URL>] = [:]
    @State private var confirmsCleanup = false
    @State private var pendingFile: CleanFileItem?
    @State private var pendingApp: InstalledApp?
    @State private var pendingStartup: StartupItem?
    @State private var appSearch = ""
    @State private var showsAllApps = false

    private var visibleRules: [CleanupRule] { junk.rules.filter { !$0.deletesPermanently } }
    private var visibleItemCount: Int {
        visibleRules.reduce(0) { $0 + junk.itemCount(forRule: $1.id) }
    }
    private var filteredApps: [InstalledApp] {
        guard !appSearch.isEmpty else { return apps.apps }
        return apps.apps.filter { $0.name.localizedStandardContains(appSearch) }
    }
    private var displayedApps: [InstalledApp] {
        showsAllApps || !appSearch.isEmpty ? filteredApps : Array(filteredApps.prefix(12))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(t("Cuidado com o Mac", "Mac Care")).font(.largeTitle.weight(.semibold))
                    Text(t("Analise primeiro. Revise os itens antes de mover qualquer arquivo para a Lixeira.",
                           "Scan first. Review items before moving any file to Trash."))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                summary
                Picker(t("Área", "Area"), selection: $area) {
                    Text(t("Limpeza", "Cleanup")).tag(Area.cleanup)
                    Text(t("Armazenamento", "Storage")).tag(Area.storage)
                    Text(t("Apps e inicialização", "Apps & Startup")).tag(Area.apps)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch area {
                case .cleanup: cleanupContent
                case .storage: storageContent
                case .apps: appsContent
                }
            }
            .padding(28)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { if junk.results.isEmpty { junk.scan() } }
        .sheet(item: $selectedRule, onDismiss: {
            selectedURLs = []
            if !cleanupPending.isEmpty { confirmsCleanup = true }
        }) { rule in
            review(rule)
        }
        .confirmationDialog(t("Mover os itens selecionados para a Lixeira?", "Move selected items to Trash?"),
                            isPresented: $confirmsCleanup) {
            Button(t("Mover para a Lixeira", "Move to Trash"), role: .destructive) {
                junk.clean(itemsByRule: cleanupPending)
                cleanupPending = [:]
            }
            Button(t("Cancelar", "Cancel"), role: .cancel) { cleanupPending = [:] }
        } message: {
            Text(t("O espaço só é liberado ao esvaziar a Lixeira.",
                   "Space is freed only after emptying Trash."))
        }
        .confirmationDialog(t("Mover arquivo para a Lixeira?", "Move file to Trash?"),
                            isPresented: Binding(get: { pendingFile != nil }, set: { if !$0 { pendingFile = nil } })) {
            Button(t("Mover para a Lixeira", "Move to Trash"), role: .destructive) {
                if let pendingFile { largeFiles.trash(urls: [pendingFile.url]) }
                pendingFile = nil
            }
        }
        .confirmationDialog(t("Desinstalar aplicativo?", "Uninstall application?"),
                            isPresented: Binding(get: { pendingApp != nil }, set: { if !$0 { pendingApp = nil } })) {
            Button(t("Mover aplicativo para a Lixeira", "Move app to Trash"), role: .destructive) {
                if let pendingApp { apps.uninstall(app: pendingApp) }
                pendingApp = nil
            }
        } message: {
            Text(t("Somente o app será movido. Preferências e documentos permanecem no Mac.",
                   "Only the app is moved. Preferences and documents remain on this Mac."))
        }
        .confirmationDialog(t("Remover item de inicialização?", "Remove startup item?"),
                            isPresented: Binding(get: { pendingStartup != nil },
                                                 set: { if !$0 { pendingStartup = nil } })) {
            Button(t("Mover para a Lixeira", "Move to Trash"), role: .destructive) {
                if let pendingStartup { startup.remove(pendingStartup) }
                pendingStartup = nil
            }
        } message: {
            Text(t("A alteração terá efeito após o próximo login.", "The change takes effect after the next login."))
        }
    }

    private var summary: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                summaryTile(t("Espaço disponível", "Available storage"),
                            bytes(metrics.snapshot.storage.availableBytes), "internaldrive")
                summaryTile(t("Itens encontrados", "Items found"),
                            "\(visibleItemCount)", "doc.on.doc")
                summaryTile(t("Memória em uso", "Memory used"),
                            metrics.snapshot.memory.usedFraction.formatted(.percent.precision(.fractionLength(0))),
                            "memorychip")
            }
        }
    }

    private func summaryTile(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
    }

    private var cleanupContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                heading(t("Análise de limpeza", "Cleanup scan"),
                        t("Caches, logs e dados temporários, agrupados por origem.",
                          "Caches, logs, and temporary data grouped by source."))
                Spacer()
                Button { junk.scan() } label: {
                    Label(t("Analisar", "Scan"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .disabled(junk.isScanning || junk.isCleaning)
            }
            if junk.isScanning || junk.isCleaning {
                ProgressView(junk.isScanning ? t("Analisando…", "Scanning…")
                                             : t("Movendo itens…", "Moving items…"))
            }
            if let last = junk.lastCleanup {
                if last.movedToTrashBytes > 0 {
                    Label(t("\(bytes(last.movedToTrashBytes)) movidos para a Lixeira",
                            "\(bytes(last.movedToTrashBytes)) moved to Trash"), systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                if !last.failures.isEmpty {
                    Text(last.failures.joined(separator: "\n")).font(.caption).foregroundStyle(.orange)
                }
            }
            ForEach(CleanupSection.allCases) { section in
                let rules = visibleRules.filter { $0.section == section && junk.itemCount(forRule: $0.id) > 0 }
                if !rules.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Label(section.title(t), systemImage: section.systemImage)
                            .font(.headline).padding(16)
                        Divider()
                        ForEach(rules) { rule in
                            Button {
                                selectedURLs = []
                                selectedRule = rule
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: rule.systemImage)
                                        .frame(width: 26).foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(t(rule.titlePT, rule.titleEN)).font(.subheadline.weight(.medium))
                                        Text(t(rule.detailPT, rule.detailEN))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer(minLength: 12)
                                    Text(bytes(junk.bytes(forRule: rule.id))).monospacedDigit()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                                .padding(14).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if rule.id != rules.last?.id { Divider().padding(.leading, 52) }
                        }
                    }
                    .orviaSettingsSurface()
                }
            }
            if !junk.isScanning && visibleItemCount == 0 {
                ContentUnavailableView(t("Nenhum item para revisar", "Nothing to review"),
                                       systemImage: "checkmark.circle",
                                       description: Text(t("Execute uma análise para ver as categorias.",
                                                           "Run a scan to see the categories.")))
            }
        }
    }

    private func review(_ rule: CleanupRule) -> some View {
        let items = junk.results[rule.id]?.items ?? []
        return NavigationStack {
            List(items) { item in
                Button {
                    if selectedURLs.contains(item.url) { selectedURLs.remove(item.url) }
                    else { selectedURLs.insert(item.url) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selectedURLs.contains(item.url) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedURLs.contains(item.url) ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).lineLimit(1)
                            Text(item.path).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(bytes(item.bytes)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(t("Mostrar no Finder", "Show in Finder")) { FileSweeper.revealInFinder(item.url) }
                }
            }
            .navigationTitle(t(rule.titlePT, rule.titleEN))
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Text(t("\(selectedURLs.count) selecionados", "\(selectedURLs.count) selected"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(t("Cancelar", "Cancel")) { selectedRule = nil }
                    Button(t("Mover para a Lixeira", "Move to Trash"), role: .destructive) {
                        cleanupPending = [rule.id: selectedURLs]
                        selectedRule = nil
                    }
                    .disabled(selectedURLs.isEmpty)
                }
                .padding()
                .background(.bar)
            }
        }
        .frame(minWidth: 650, minHeight: 440)
    }

    private var storageContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading(t("Entenda o armazenamento", "Understand storage"),
                    t("Veja onde está o espaço. Arquivos pessoais exigem revisão individual.",
                      "See where space is used. Personal files require individual review."))
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(t("Pastas maiores", "Largest folders"), systemImage: "folder").font(.headline)
                    Spacer()
                    Button(t("Analisar", "Scan")) { diskMap.scan() }
                        .buttonStyle(.glass).disabled(diskMap.isScanning)
                }
                if diskMap.isScanning { ProgressView() }
                ForEach(Array((diskMap.root?.children ?? []).prefix(12))) { node in
                    HStack {
                        Image(systemName: node.isDirectory ? "folder" : "doc").foregroundStyle(.secondary)
                        Text(node.name)
                        Spacer()
                        Text(bytes(node.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        Button(t("Mostrar", "Reveal")) { FileSweeper.revealInFinder(node.url) }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .padding(16).orviaSettingsSurface()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(t("Arquivos grandes", "Large files"), systemImage: "externaldrive").font(.headline)
                    Spacer()
                    Picker(t("Tamanho mínimo", "Minimum size"), selection: $largeFiles.threshold) {
                        ForEach(LargeOldFilesService.SizeThreshold.allCases) { threshold in
                            Text(threshold.label).tag(threshold)
                        }
                    }
                    .frame(width: 160)
                    Button(t("Analisar", "Scan")) { largeFiles.scan() }
                        .buttonStyle(.glass).disabled(largeFiles.isScanning)
                }
                if largeFiles.isScanning { ProgressView() }
                if let error = largeFiles.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                ForEach(Array(largeFiles.files.prefix(30))) { file in
                    HStack(spacing: 10) {
                        Image(systemName: "doc").foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(file.name).lineLimit(1)
                            Text(file.path).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(bytes(file.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        Button(t("Mostrar", "Reveal")) { FileSweeper.revealInFinder(file.url) }
                            .buttonStyle(.borderless)
                        Button(t("Lixeira", "Trash"), role: .destructive) { pendingFile = file }
                            .buttonStyle(.borderless)
                    }
                    .font(.subheadline)
                }
            }
            .padding(16).orviaSettingsSurface()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(t("Duplicatas exatas", "Exact duplicates"), systemImage: "square.on.square")
                        .font(.headline)
                    Spacer()
                    Button(t("Analisar", "Scan")) { duplicates.scan() }
                        .buttonStyle(.glass).disabled(duplicates.isScanning)
                }
                if duplicates.isScanning { ProgressView() }
                ForEach(Array(duplicates.groups.prefix(20))) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(t("\(group.items.count) cópias · \(bytes(group.wastedBytes))",
                               "\(group.items.count) copies · \(bytes(group.wastedBytes))"))
                            .font(.subheadline.weight(.medium))
                        ForEach(group.items) { item in
                            HStack {
                                Text(item.name).lineLimit(1)
                                Spacer()
                                Button(t("Mostrar no Finder", "Show in Finder")) {
                                    FileSweeper.revealInFinder(item.url)
                                }
                                .buttonStyle(.borderless)
                            }
                            .font(.caption)
                        }
                    }
                    Divider()
                }
            }
            .padding(16).orviaSettingsSurface()
        }
    }

    private var appsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading(t("Apps e inicialização", "Apps & Startup"),
                    t("Desinstale apps e revise apenas itens de inicialização do usuário.",
                      "Uninstall apps and review only user startup items."))
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(t("Aplicativos instalados", "Installed apps"), systemImage: "app").font(.headline)
                    Spacer()
                    Button(t("Atualizar", "Refresh")) { apps.refresh() }
                        .buttonStyle(.glass).disabled(apps.isLoading || apps.isUninstalling)
                }
                if apps.isLoading || apps.isUninstalling { ProgressView() }
                if let error = apps.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
                TextField(t("Buscar aplicativo", "Search apps"), text: $appSearch)
                    .textFieldStyle(.roundedBorder)
                ForEach(displayedApps) { app in
                    HStack(spacing: 10) {
                        Image(nsImage: app.icon).resizable().frame(width: 28, height: 28)
                        Text(app.name).lineLimit(1)
                        Spacer()
                        Text(bytes(app.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        Button(t("Mostrar", "Reveal")) { FileSweeper.revealInFinder(app.url) }
                            .buttonStyle(.borderless)
                        if !FileSweeper.isProtected(app.url) {
                            Button(t("Desinstalar", "Uninstall"), role: .destructive) { pendingApp = app }
                                .buttonStyle(.borderless)
                        }
                    }
                    .font(.subheadline)
                }
                if !showsAllApps && appSearch.isEmpty && apps.apps.count > displayedApps.count {
                    Button(t("Ver todos os \(apps.apps.count) apps", "Show all \(apps.apps.count) apps")) {
                        showsAllApps = true
                    }
                    .buttonStyle(.link)
                }
            }
            .padding(16).orviaSettingsSurface()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(t("Itens de inicialização", "Startup items"), systemImage: "power").font(.headline)
                    Spacer()
                    Button(t("Atualizar", "Refresh")) { startup.refresh() }
                        .buttonStyle(.glass).disabled(startup.isLoading)
                }
                if startup.isLoading { ProgressView() }
                if let error = startup.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
                ForEach(startup.items) { item in
                    HStack(spacing: 10) {
                        Image(systemName: "gearshape").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label).lineLimit(1)
                            if let path = item.programPath {
                                Text(path).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                        Spacer()
                        Button(t("Mostrar", "Reveal")) { FileSweeper.revealInFinder(item.url) }
                            .buttonStyle(.borderless)
                        if item.isRemovable {
                            Button(t("Remover", "Remove"), role: .destructive) { pendingStartup = item }
                                .buttonStyle(.borderless)
                        }
                    }
                    .font(.subheadline)
                }
            }
            .padding(16).orviaSettingsSurface()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(t("Processos em atividade", "Active processes"), systemImage: "cpu")
                        .font(.headline)
                    Spacer()
                    Button(t("Monitor de Atividade", "Activity Monitor")) {
                        ActivityMonitorLauncher.open(for: .cpu)
                    }
                    .buttonStyle(.glass)
                }
                ForEach(startup.processes) { process in
                    HStack {
                        Text(process.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(String(format: "CPU %.1f%% · RAM %.1f%%",
                                    process.cpuPercent, process.memoryPercent))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16).orviaSettingsSurface()
        }
        .onAppear {
            if apps.apps.isEmpty { apps.refresh() }
            if startup.items.isEmpty { startup.refresh() }
        }
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func bytes(_ value: UInt64) -> String { CleanFormat.bytes(value) }
    private func t(_ pt: String, _ en: String) -> String { settings.text(ptBR: pt, en: en) }
}
