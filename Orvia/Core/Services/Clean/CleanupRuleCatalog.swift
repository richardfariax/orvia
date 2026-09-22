import Foundation

/// Nível de segurança de uma regra de limpeza.
enum CleanupSafety {
    /// Recriado automaticamente pelo sistema/app; remoção sem efeitos colaterais.
    case safe
    /// Remoção segura, mas com efeito perceptível (ex.: perder restauração de
    /// janelas, backups). Exige revisão consciente do usuário.
    case review
}

enum CleanupSection: String, CaseIterable, Identifiable {
    case system
    case browsers
    case developer
    case apps
    case bigItems

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .system: return "gearshape"
        case .browsers: return "safari"
        case .developer: return "hammer"
        case .apps: return "square.grid.2x2"
        case .bigItems: return "shippingbox"
        }
    }

    func title(_ t: (String, String) -> String) -> String {
        switch self {
        case .system: return t("Sistema", "System")
        case .browsers: return t("Navegadores", "Browsers")
        case .developer: return t("Desenvolvedor", "Developer")
        case .apps: return t("Aplicativos", "Applications")
        case .bigItems: return t("Itens grandes", "Big items")
        }
    }
}

/// Regra de limpeza curada: o que varrer, como e com quais salvaguardas.
struct CleanupRule: Identifiable {
    enum Mode {
        /// Cada filho imediato das raízes é um item removível.
        case children
        /// A raiz inteira é um único item.
        case wholeFolder
        /// Apenas arquivos com estas extensões (minúsculas) nas raízes.
        case filesWithExtensions(Set<String>)
    }

    let id: String
    let section: CleanupSection
    let titlePT: String
    let titleEN: String
    let detailPT: String
    let detailEN: String
    let systemImage: String
    let roots: [URL]
    let mode: Mode
    let safety: CleanupSafety
    /// Entra na seleção padrão e na limpeza de 1 clique da Análise Inteligente.
    let selectedByDefault: Bool
    /// Ignora itens modificados há menos de N dias (proteção contra apps em uso).
    let minAgeDays: Int?
    /// Primeiro componente sob a raiz a ignorar (evita sobreposição entre regras).
    let excludedFirstComponents: Set<String>
    let includeHidden: Bool
    /// Apaga em definitivo em vez de mover para a Lixeira (apenas a própria Lixeira).
    let deletesPermanently: Bool

    init(
        id: String,
        section: CleanupSection,
        titlePT: String, titleEN: String,
        detailPT: String, detailEN: String,
        systemImage: String,
        roots: [URL],
        mode: Mode = .children,
        safety: CleanupSafety = .safe,
        selectedByDefault: Bool = true,
        minAgeDays: Int? = nil,
        excludedFirstComponents: Set<String> = [],
        includeHidden: Bool = false,
        deletesPermanently: Bool = false
    ) {
        self.id = id
        self.section = section
        self.titlePT = titlePT
        self.titleEN = titleEN
        self.detailPT = detailPT
        self.detailEN = detailEN
        self.systemImage = systemImage
        self.roots = roots
        self.mode = mode
        self.safety = safety
        self.selectedByDefault = selectedByDefault
        self.minAgeDays = minAgeDays
        self.excludedFirstComponents = excludedFirstComponents
        self.includeHidden = includeHidden
        self.deletesPermanently = deletesPermanently
    }
}

/// Catálogo de regras com níveis de risco explícitos:
/// caminhos conhecidos, seguros e recriáveis, curados por ferramenta.
enum CleanupRuleCatalog {
    /// Caches de navegadores e apps cobertos por regras próprias — o cache
    /// genérico ignora estes primeiros componentes para não contar em dobro.
    private static let dedicatedCacheFolders: Set<String> = [
        "com.apple.Safari", "Google", "com.google.Chrome", "Firefox", "Mozilla",
        "company.thebrowser.Browser", "com.microsoft.edgemac",
        "com.brave.Browser", "BraveSoftware", "Homebrew", "Yarn", "pip",
        "CocoaPods", "go-build", "com.spotify.client"
    ]

    static func rules() -> [CleanupRule] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let caches = library.appendingPathComponent("Caches", isDirectory: true)
        let appSupport = library.appendingPathComponent("Application Support", isDirectory: true)
        let xcode = library.appendingPathComponent("Developer/Xcode", isDirectory: true)

        func c(_ path: String) -> URL { caches.appendingPathComponent(path, isDirectory: true) }
        func s(_ path: String) -> URL { appSupport.appendingPathComponent(path, isDirectory: true) }

        return [
            // MARK: Sistema
            CleanupRule(
                id: "system.appCaches", section: .system,
                titlePT: "Caches de aplicativos", titleEN: "Application caches",
                detailPT: "~/Library/Caches — apps recriam quando necessário (só itens com 3+ dias)",
                detailEN: "~/Library/Caches — apps recreate on demand (only items 3+ days old)",
                systemImage: "internaldrive",
                roots: [caches],
                minAgeDays: 3,
                excludedFirstComponents: dedicatedCacheFolders
            ),
            CleanupRule(
                id: "system.logs", section: .system,
                titlePT: "Arquivos de log", titleEN: "Log files",
                detailPT: "~/Library/Logs — registros de diagnóstico acumulados",
                detailEN: "~/Library/Logs — accumulated diagnostic logs",
                systemImage: "doc.text",
                roots: [library.appendingPathComponent("Logs", isDirectory: true)]
            ),
            CleanupRule(
                id: "system.mailDownloads", section: .system,
                titlePT: "Anexos do Mail em cache", titleEN: "Cached Mail attachments",
                detailPT: "Cópias locais de anexos — os originais continuam no e-mail",
                detailEN: "Local attachment copies — originals stay in your email",
                systemImage: "envelope.open",
                roots: [library.appendingPathComponent(
                    "Containers/com.apple.mail/Data/Library/Mail Downloads", isDirectory: true)]
            ),
            CleanupRule(
                id: "system.incompleteDownloads", section: .system,
                titlePT: "Downloads incompletos", titleEN: "Incomplete downloads",
                detailPT: "Arquivos .download, .crdownload e .part abandonados",
                detailEN: "Abandoned .download, .crdownload and .part files",
                systemImage: "xmark.icloud",
                roots: [home.appendingPathComponent("Downloads", isDirectory: true)],
                mode: .filesWithExtensions(["download", "crdownload", "part", "partial", "opdownload"]),
                safety: .review, selectedByDefault: false,
                minAgeDays: 1
            ),
            CleanupRule(
                id: "system.savedState", section: .system,
                titlePT: "Estados de janelas salvos", titleEN: "Saved window states",
                detailPT: "Apps esquecem as janelas abertas da última sessão (30+ dias)",
                detailEN: "Apps forget last session's open windows (30+ days old)",
                systemImage: "macwindow.on.rectangle",
                roots: [library.appendingPathComponent("Saved Application State", isDirectory: true)],
                safety: .review, selectedByDefault: false, minAgeDays: 30
            ),
            CleanupRule(
                id: "system.tempFiles", section: .system,
                titlePT: "Arquivos temporários antigos", titleEN: "Old temporary files",
                detailPT: "Pasta temporária do usuário — só itens parados há 7+ dias",
                detailEN: "User temp folder — only items untouched for 7+ days",
                systemImage: "clock.badge.xmark",
                roots: [FileManager.default.temporaryDirectory],
                safety: .review, selectedByDefault: false, minAgeDays: 7
            ),
            CleanupRule(
                id: "system.oldDownloads", section: .system,
                titlePT: "Downloads antigos", titleEN: "Old downloads",
                detailPT: "Itens sem modificação há mais de 30 dias",
                detailEN: "Items untouched for over 30 days",
                systemImage: "arrow.down.circle",
                roots: [home.appendingPathComponent("Downloads", isDirectory: true)],
                safety: .review, selectedByDefault: false, minAgeDays: 30
            ),
            CleanupRule(
                id: "system.trash", section: .system,
                titlePT: "Lixeira", titleEN: "Trash",
                detailPT: "Esvazia em definitivo — não pode ser desfeito",
                detailEN: "Empties permanently — cannot be undone",
                systemImage: "trash",
                roots: [home.appendingPathComponent(".Trash", isDirectory: true)],
                safety: .review, selectedByDefault: false,
                includeHidden: true, deletesPermanently: true
            ),

            // MARK: Navegadores
            CleanupRule(
                id: "browser.safari", section: .browsers,
                titlePT: "Cache do Safari", titleEN: "Safari cache",
                detailPT: "Páginas e imagens em cache — histórico e senhas intactos",
                detailEN: "Cached pages and images — history and passwords untouched",
                systemImage: "safari",
                roots: [c("com.apple.Safari")], mode: .wholeFolder
            ),
            CleanupRule(
                id: "browser.chrome", section: .browsers,
                titlePT: "Cache do Chrome", titleEN: "Chrome cache",
                detailPT: "Somente cache — perfis, senhas e extensões intactos",
                detailEN: "Cache only — profiles, passwords and extensions untouched",
                systemImage: "globe",
                roots: [c("Google/Chrome"), c("com.google.Chrome")], mode: .wholeFolder
            ),
            CleanupRule(
                id: "browser.firefox", section: .browsers,
                titlePT: "Cache do Firefox", titleEN: "Firefox cache",
                detailPT: "Somente cache — perfis e dados intactos",
                detailEN: "Cache only — profiles and data untouched",
                systemImage: "flame",
                roots: [c("Firefox"), c("Mozilla")], mode: .wholeFolder
            ),
            CleanupRule(
                id: "browser.arc", section: .browsers,
                titlePT: "Cache do Arc", titleEN: "Arc cache",
                detailPT: "Somente cache do navegador Arc",
                detailEN: "Arc browser cache only",
                systemImage: "circle.grid.cross",
                roots: [c("company.thebrowser.Browser")], mode: .wholeFolder
            ),
            CleanupRule(
                id: "browser.edge", section: .browsers,
                titlePT: "Cache do Edge", titleEN: "Edge cache",
                detailPT: "Somente cache do Microsoft Edge",
                detailEN: "Microsoft Edge cache only",
                systemImage: "e.circle",
                roots: [c("com.microsoft.edgemac")], mode: .wholeFolder
            ),
            CleanupRule(
                id: "browser.brave", section: .browsers,
                titlePT: "Cache do Brave", titleEN: "Brave cache",
                detailPT: "Somente cache do Brave",
                detailEN: "Brave cache only",
                systemImage: "shield",
                roots: [c("com.brave.Browser"), c("BraveSoftware")], mode: .wholeFolder
            ),

            // MARK: Desenvolvedor
            CleanupRule(
                id: "dev.derivedData", section: .developer,
                titlePT: "Xcode DerivedData", titleEN: "Xcode DerivedData",
                detailPT: "Builds intermediários — recompilados no próximo build",
                detailEN: "Intermediate builds — recompiled on next build",
                systemImage: "hammer",
                roots: [xcode.appendingPathComponent("DerivedData", isDirectory: true)]
            ),
            CleanupRule(
                id: "dev.deviceSupport", section: .developer,
                titlePT: "iOS DeviceSupport", titleEN: "iOS DeviceSupport",
                detailPT: "Símbolos de versões antigas de iOS — rebaixados ao conectar o aparelho",
                detailEN: "Old iOS version symbols — re-downloaded when device connects",
                systemImage: "iphone",
                roots: [xcode.appendingPathComponent("iOS DeviceSupport", isDirectory: true)]
            ),
            CleanupRule(
                id: "dev.simulatorCaches", section: .developer,
                titlePT: "Caches de simulador", titleEN: "Simulator caches",
                detailPT: "CoreSimulator/Caches — recriados pelo Xcode",
                detailEN: "CoreSimulator/Caches — recreated by Xcode",
                systemImage: "ipad.and.iphone",
                roots: [library.appendingPathComponent("Developer/CoreSimulator/Caches", isDirectory: true)],
                mode: .wholeFolder
            ),
            CleanupRule(
                id: "dev.xcodeArchives", section: .developer,
                titlePT: "Xcode Archives", titleEN: "Xcode Archives",
                detailPT: "Contêm dSYMs de builds publicados — remova só o que não precisa mais",
                detailEN: "Contain dSYMs of shipped builds — remove only what you no longer need",
                systemImage: "archivebox",
                roots: [xcode.appendingPathComponent("Archives", isDirectory: true)],
                safety: .review, selectedByDefault: false
            ),
            CleanupRule(
                id: "dev.npm", section: .developer,
                titlePT: "Cache do npm", titleEN: "npm cache",
                detailPT: "~/.npm/_cacache — pacotes baixam de novo sob demanda",
                detailEN: "~/.npm/_cacache — packages re-download on demand",
                systemImage: "shippingbox",
                roots: [home.appendingPathComponent(".npm/_cacache", isDirectory: true)],
                mode: .wholeFolder
            ),
            CleanupRule(
                id: "dev.yarn", section: .developer,
                titlePT: "Cache do Yarn", titleEN: "Yarn cache",
                detailPT: "~/Library/Caches/Yarn",
                detailEN: "~/Library/Caches/Yarn",
                systemImage: "shippingbox",
                roots: [c("Yarn")], mode: .wholeFolder
            ),
            CleanupRule(
                id: "dev.pip", section: .developer,
                titlePT: "Cache do pip", titleEN: "pip cache",
                detailPT: "~/Library/Caches/pip",
                detailEN: "~/Library/Caches/pip",
                systemImage: "shippingbox",
                roots: [c("pip")], mode: .wholeFolder
            ),
            CleanupRule(
                id: "dev.homebrew", section: .developer,
                titlePT: "Cache do Homebrew", titleEN: "Homebrew cache",
                detailPT: "Instaladores baixados — equivalente a brew cleanup",
                detailEN: "Downloaded bottles — equivalent to brew cleanup",
                systemImage: "mug",
                roots: [c("Homebrew")]
            ),
            CleanupRule(
                id: "dev.cocoapods", section: .developer,
                titlePT: "Cache do CocoaPods", titleEN: "CocoaPods cache",
                detailPT: "~/Library/Caches/CocoaPods",
                detailEN: "~/Library/Caches/CocoaPods",
                systemImage: "shippingbox",
                roots: [c("CocoaPods")], mode: .wholeFolder
            ),
            CleanupRule(
                id: "dev.gradle", section: .developer,
                titlePT: "Cache do Gradle", titleEN: "Gradle cache",
                detailPT: "~/.gradle/caches — dependências baixam de novo no próximo build",
                detailEN: "~/.gradle/caches — dependencies re-download on next build",
                systemImage: "shippingbox",
                roots: [home.appendingPathComponent(".gradle/caches", isDirectory: true)],
                mode: .wholeFolder
            ),
            CleanupRule(
                id: "dev.goBuild", section: .developer,
                titlePT: "Cache de build do Go", titleEN: "Go build cache",
                detailPT: "~/Library/Caches/go-build",
                detailEN: "~/Library/Caches/go-build",
                systemImage: "shippingbox",
                roots: [c("go-build")], mode: .wholeFolder
            ),
            CleanupRule(
                id: "dev.cargo", section: .developer,
                titlePT: "Cache do Cargo (Rust)", titleEN: "Cargo cache (Rust)",
                detailPT: "~/.cargo/registry/cache — crates baixam de novo sob demanda",
                detailEN: "~/.cargo/registry/cache — crates re-download on demand",
                systemImage: "shippingbox",
                roots: [home.appendingPathComponent(".cargo/registry/cache", isDirectory: true)],
                mode: .wholeFolder
            ),

            // MARK: Apps
            CleanupRule(
                id: "app.spotify", section: .apps,
                titlePT: "Cache do Spotify", titleEN: "Spotify cache",
                detailPT: "Músicas em cache — downloads offline não são afetados",
                detailEN: "Streaming cache — offline downloads unaffected",
                systemImage: "music.note",
                roots: [c("com.spotify.client"), s("Spotify/PersistentCache")],
                mode: .wholeFolder
            ),
            CleanupRule(
                id: "app.slack", section: .apps,
                titlePT: "Cache do Slack", titleEN: "Slack cache",
                detailPT: "Somente cache — conversas ficam no servidor",
                detailEN: "Cache only — conversations live on the server",
                systemImage: "bubble.left.and.bubble.right",
                roots: [s("Slack/Cache"), s("Slack/Service Worker/CacheStorage")],
                mode: .wholeFolder
            ),
            CleanupRule(
                id: "app.discord", section: .apps,
                titlePT: "Cache do Discord", titleEN: "Discord cache",
                detailPT: "Somente cache — mensagens ficam no servidor",
                detailEN: "Cache only — messages live on the server",
                systemImage: "gamecontroller",
                roots: [s("discord/Cache"), s("discord/Code Cache")],
                mode: .wholeFolder
            ),
            CleanupRule(
                id: "app.vscode", section: .apps,
                titlePT: "Cache do VS Code", titleEN: "VS Code cache",
                detailPT: "Cache e dados temporários — extensões e ajustes intactos",
                detailEN: "Cache and temp data — extensions and settings untouched",
                systemImage: "chevron.left.forwardslash.chevron.right",
                roots: [s("Code/Cache"), s("Code/CachedData"), s("Code/CachedExtensionVSIXs")],
                mode: .wholeFolder
            ),

            // MARK: Itens grandes
            CleanupRule(
                id: "big.iosBackups", section: .bigItems,
                titlePT: "Backups de iPhone/iPad", titleEN: "iPhone/iPad backups",
                detailPT: "Backups locais completos — confirme que há backup no iCloud antes",
                detailEN: "Full local backups — confirm you have iCloud backups first",
                systemImage: "externaldrive.badge.icloud",
                roots: [s("MobileSync/Backup")],
                safety: .review, selectedByDefault: false
            )
        ]
    }
}
