import Foundation

enum VolumeAction: Equatable {
    case up
    case down
    case mute
}

enum BrightnessAction: Equatable {
    case up
    case down
}

/// Comandos de ação do Mac / Orvia. Conversa livre não entra aqui — vai para a IA.
enum VoiceCommand: Equatable {
    case openApp(String)
    case screenshotFull
    case screenshotArea
    case analyzeScreen
    case openPanel
    case closePanel
    case copyItem(Int)
    case copyLastItem
    case pasteItem(Int)
    case pasteLast
    case readLastItem
    case favoriteItem(Int)
    case deleteItem(Int)
    case pinItem(Int)
    case historyCount
    case clearHistory
    case dictate(String)
    case formatJSONLast
    case transformLast(ClipboardTextTransform)
    case saveSnippet(String)
    case pasteSnippet(String)
    case listSnippets
    case stackAdd(Int)
    case stackPasteNext
    case stackClear
    case pauseMonitoring
    case resumeMonitoring
    case openWebsite(String)
    case webSearch(String)
    case searchHistory(String)
    case showFilter(ClipboardPanelFilter)
    case openFolder(VoiceCommandCatalog.Folder)
    case currentTime
    case currentDate
    case dayOfWeek
    case weather
    case calculate(String)
    case setUserName(String)
    case openDeveloperProfile
    case openSettings
    case setVoiceEnabled(Bool)
    case lockScreen
    case openSpotlight
    case volumeAdjust(VolumeAction)
    case brightnessAdjust(BrightnessAction)
}

enum VoiceCommandParser {
    static func parse(_ rawText: String) -> VoiceCommand? {
        let original = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return nil }

        let normalized = normalize(original)

        // Ditado tem prioridade — evita "digite bom dia" virar conversa.
        if let dictated = extractSuffix(after: ["digite", "escreva", "type", "insira", "cole o texto"], normalized: normalized, original: original) {
            return .dictate(dictated)
        }

        // MARK: Matemática (ação com resultado real)

        if let result = VoiceCommandCatalog.evaluateMath(normalized) {
            return .calculate(result)
        }

        // MARK: Ação — abrir LinkedIn do desenvolvedor

        if AssistantIntentDetector.isDeveloperProfileRequest(normalized) {
            return .openDeveloperProfile
        }

        if let name = extractSuffix(after: ["meu nome e", "me chame de", "pode me chamar de", "my name is", "call me"], normalized: normalized, original: original) {
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                return .setUserName(cleaned)
            }
        }

        if normalized.contains("linkedin") {
            return .openWebsite("linkedin.com")
        }

        // MARK: Tempo e clima

        if containsAny(normalized, ["que horas", "que hora sao", "what time", "hora atual"]) {
            return .currentTime
        }

        if containsAny(normalized, ["que dia da semana", "qual o dia da semana", "what day of the week"]) {
            return .dayOfWeek
        }

        if containsAny(normalized, ["que dia e", "data de hoje", "qual e a data", "what day", "what is the date", "whats the date", "data de hoje"]) {
            return .currentDate
        }

        if containsAny(normalized, ["quantos graus", "temperatura", "previsao do tempo", "como esta o tempo", "como ta o tempo", "clima", "weather", "how hot", "how cold", "vai chover"]) {
            return .weather
        }

        // MARK: Configurações e voz

        if containsAny(normalized, ["abra as configuracoes", "abra as preferencias", "abrir configuracoes", "abrir preferencias", "open settings", "open preferences"]) {
            return .openSettings
        }

        if containsAny(normalized, ["desative comandos de voz", "desativa comandos de voz", "pare de ouvir", "desligue o microfone", "disable voice", "turn off voice"]) {
            return .setVoiceEnabled(false)
        }
        if containsAny(normalized, ["ative comandos de voz", "ativa comandos de voz", "ligue o microfone", "ligue a voz", "enable voice", "turn on voice"]) {
            return .setVoiceEnabled(true)
        }

        // MARK: Sistema

        if containsAny(normalized, [
            "bloqueie a tela", "bloquear tela", "trave a tela", "bloquear o mac", "bloqueie o mac",
            "lock screen", "lock the screen", "lock mac"
        ]) {
            return .lockScreen
        }

        if containsAny(normalized, [
            "abra o spotlight", "abrir spotlight", "open spotlight", "pesquisa do mac",
            "abrir busca", "abra a busca", "busca do sistema", "open search"
        ]) {
            return .openSpotlight
        }

        if let brightness = parseBrightnessAction(normalized) {
            return .brightnessAdjust(brightness)
        }

        if let volume = parseVolumeAction(normalized) {
            return .volumeAdjust(volume)
        }

        if let folder = VoiceCommandCatalog.Folder.match(normalized),
           containsAny(normalized, ["abra", "abrir", "abre", "open", "acesse", "mostre", "mostrar"]) {
            return .openFolder(folder)
        }

        // MARK: Tela

        if containsAny(normalized, [
            "veja o que esta na tela", "veja o que tem na tela", "veja a tela",
            "analise o que esta na tela", "analise o que tem na tela", "analise a tela", "analisa a tela",
            "o que tem na tela", "o que esta na tela", "o que tem na minha tela",
            "leia a tela", "leia o que esta na tela", "leia o que tem na tela",
            "descreva a tela", "descreva o que esta na tela", "descreva o que tem na tela",
            "me fale o que tem na tela", "me diga o que tem na tela",
            "look at the screen", "what is on the screen", "what's on the screen", "whats on the screen",
            "read the screen", "analyze the screen", "describe the screen"
        ]) {
            return .analyzeScreen
        }

        if containsAny(normalized, ["print", "captura de tela", "capture a tela", "capturar a tela", "screenshot", "tire um print", "tirar print"]) {
            if containsAny(normalized, ["area", "selecao", "parte", "pedaco", "region", "selection", "area of"]) {
                return .screenshotArea
            }
            return .screenshotFull
        }

        // MARK: Painel e filtros

        if containsAny(normalized, [
            "abrir painel", "abra o painel", "abre o painel", "mostrar historico", "mostre o historico",
            "abrir historico", "abra o historico", "mostre o clipboard", "abra o clipboard",
            "open panel", "show history", "open history", "show clipboard"
        ]) {
            return .openPanel
        }

        if containsAny(normalized, ["fechar painel", "feche o painel", "fecha o painel", "close panel", "hide panel", "esconder painel"]) {
            return .closePanel
        }

        if containsAny(normalized, ["mostre favoritos", "mostrar favoritos", "abra favoritos", "show favorites"]) {
            return .showFilter(.favorites)
        }
        if containsAny(normalized, ["mostre fixados", "mostrar fixados", "abra fixados", "show pinned"]) {
            return .showFilter(.pinned)
        }
        if containsAny(normalized, ["mostre snippets", "mostrar snippets", "lista de snippets", "list snippets"]) {
            return .showFilter(.snippets)
        }
        if containsAny(normalized, ["mostre imagens", "mostrar imagens", "show images"]) {
            return .showFilter(.imagesOnly)
        }
        if containsAny(normalized, ["mostre textos", "mostrar textos", "show text"]) {
            return .showFilter(.textOnly)
        }

        if containsAny(normalized, ["limpar historico", "limpe o historico", "apagar historico", "esvaziar historico", "clear history"]) {
            return .clearHistory
        }

        if containsAny(normalized, [
            "quantos itens", "quantas copias", "quantos itens no historico", "tamanho do historico",
            "how many items", "history count", "how many copies"
        ]) {
            return .historyCount
        }

        // MARK: Pilha

        if containsAny(normalized, ["limpar pilha", "limpe a pilha", "esvaziar pilha", "clear stack"]) {
            return .stackClear
        }

        if containsAny(normalized, ["cole a pilha", "colar pilha", "proximo da pilha", "cola o proximo", "cole o proximo", "paste stack", "paste next"]) {
            return .stackPasteNext
        }

        if containsAny(normalized, ["adicione", "adiciona", "add"]) && containsAny(normalized, ["pilha", "stack"]) {
            if let number = firstNumber(in: normalized) {
                return .stackAdd(number)
            }
        }

        // MARK: Monitoramento

        if containsAny(normalized, ["pausar monitoramento", "pause o monitoramento", "pause monitoring", "parar de ouvir o clipboard", "pausar clipboard"]) {
            return .pauseMonitoring
        }

        if containsAny(normalized, ["retomar monitoramento", "retome o monitoramento", "resume monitoring", "voltar a monitorar"]) {
            return .resumeMonitoring
        }

        // MARK: Transformações de texto

        if containsAny(normalized, ["formate o json", "formata o json", "formatar json", "format json", "pretty json"]) {
            return .formatJSONLast
        }

        if let transform = parseTextTransform(normalized) {
            return .transformLast(transform)
        }

        // MARK: Snippets

        if containsAny(normalized, ["liste os snippets", "listar snippets", "quais snippets", "list snippets"]) {
            return .listSnippets
        }

        if let name = extractSuffix(after: ["salve como", "salvar como", "salva como", "save as"], normalized: normalized, original: original) {
            let cleaned = cleanSnippetName(name)
            if !cleaned.isEmpty {
                return .saveSnippet(cleaned)
            }
        }

        if let name = extractSuffix(after: ["cole o snippet", "colar snippet", "cola o snippet", "paste snippet"], normalized: normalized, original: original) {
            let cleaned = cleanSnippetName(name)
            if !cleaned.isEmpty {
                return .pasteSnippet(cleaned)
            }
        }

        // MARK: Histórico — ler, copiar, colar, favoritar, fixar, apagar

        if containsAny(normalized, [
            "o que eu copiei", "o que copiei", "leia o ultimo", "leia o último",
            "o que tem no clipboard", "o que tem na area de transferencia",
            "what did i copy", "read the last", "what's in the clipboard"
        ]) {
            return .readLastItem
        }

        if containsAny(normalized, ["copie o ultimo", "copiar ultimo", "copy last", "copia o ultimo"]) {
            return .copyLastItem
        }

        if containsAny(normalized, ["apague o item", "delete item", "remova o item", "remove item", "exclua o item"]) {
            if let number = firstNumber(in: normalized) {
                return .deleteItem(number)
            }
        }

        if containsAny(normalized, ["fixe o item", "fixar item", "pin item", "desfixe o item", "desafixar item", "unpin item"]) {
            if let number = firstNumber(in: normalized) {
                return .pinItem(number)
            }
        }

        if containsAny(normalized, ["favorite o item", "favoritar item", "favorita o item", "favorite item", "desfavorite o item"]) {
            if let number = firstNumber(in: normalized) {
                return .favoriteItem(number)
            }
        }

        if containsAny(normalized, ["copie", "copiar", "copia", "copy"]) && containsAny(normalized, ["item"]) {
            if let number = firstNumber(in: normalized) {
                return .copyItem(number)
            }
        }

        if containsAny(normalized, ["cole", "colar", "cola", "paste"]) {
            if containsAny(normalized, ["ultimo", "last"]) {
                return .pasteLast
            }
            if containsAny(normalized, ["item"]), let number = firstNumber(in: normalized) {
                return .pasteItem(number)
            }
        }

        // MARK: Busca

        if let query = extractSuffix(
            after: [
                "busque no historico", "buscar no historico", "procure no historico",
                "search history", "find in history"
            ],
            normalized: normalized,
            original: original
        ) {
            let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                return .searchHistory(cleaned)
            }
        }

        if let query = extractSuffix(
            after: ["pesquise por", "pesquisar por", "pesquise", "pesquisar", "procure por", "procure", "busque por", "busque", "search for", "search", "google"],
            normalized: normalized,
            original: original
        ) {
            let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                return .webSearch(cleaned)
            }
        }

        if let site = extractSuffix(
            after: ["abra o site", "abre o site", "abrir o site", "abra site", "acesse o site", "acesse", "open the site", "open site", "open website", "go to"],
            normalized: normalized,
            original: original
        ) {
            let cleaned = cleanWebsite(site)
            if !cleaned.isEmpty {
                return .openWebsite(cleaned)
            }
        }

        if let appName = extractSuffix(after: ["abra", "abrir", "abre", "open", "iniciar", "start"], normalized: normalized, original: original) {
            let cleaned = cleanAppName(appName)
            if !cleaned.isEmpty {
                if let domain = resolveWebsiteAlias(cleaned) {
                    return .openWebsite(domain)
                }
                let asWebsite = cleanWebsite(cleaned)
                if asWebsite.contains(".") {
                    return .openWebsite(asWebsite)
                }
                return .openApp(cleaned)
            }
        }

        // Conversa / perguntas → nil → executor manda para a IA.
        return nil
    }

    /// Normaliza fala em endereço: "github ponto com" -> "github.com".
    private static func cleanWebsite(_ text: String) -> String {
        var cleaned = text
            .lowercased()
            .replacingOccurrences(of: " ponto ", with: ".")
            .replacingOccurrences(of: " dot ", with: ".")
            .replacingOccurrences(of: " barra ", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let articles = ["o site ", "o ", "a ", "the "]
        for article in articles where cleaned.hasPrefix(article) {
            cleaned = String(cleaned.dropFirst(article.count))
        }

        // Se ainda houver espaços, mantém apenas se parecer domínio falado junto.
        return cleaned
    }

    // MARK: - Helpers

    static func normalize(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()
            .components(separatedBy: CharacterSet.punctuationCharacters)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    /// Correspondência exata ou frase que começa com o padrão (evita falsos positivos em ditado).
    private static func matchesPhrase(_ normalized: String, _ phrase: String) -> Bool {
        normalized == phrase || normalized.hasPrefix(phrase + " ")
    }

    /// Retorna o sufixo do texto ORIGINAL após a primeira ocorrência de qualquer keyword,
    /// preservando maiúsculas/acentos (importante para ditado e nomes de apps).
    private static func extractSuffix(after keywords: [String], normalized: String, original: String) -> String? {
        let originalFolded = original
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()

        for keyword in keywords {
            guard normalized.contains(keyword),
                  let foldedRange = originalFolded.range(of: keyword) else { continue }

            let offset = originalFolded.distance(from: originalFolded.startIndex, to: foldedRange.upperBound)
            guard let suffixStart = original.index(original.startIndex, offsetBy: offset, limitedBy: original.endIndex) else {
                continue
            }

            let suffix = String(original[suffixStart...])
            let trimmed = suffix.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func cleanAppName(_ name: String) -> String {
        var words = name.split(separator: " ").map(String.init)
        let articles: Set<String> = ["o", "a", "os", "as", "the", "um", "uma", "aplicativo", "app"]
        while let first = words.first, articles.contains(VoiceCommandParser.normalize(first)) {
            words.removeFirst()
        }
        return words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanSnippetName(_ name: String) -> String {
        var words = name.split(separator: " ").map(String.init)
        let articles: Set<String> = ["o", "a", "the", "snippet"]
        while let first = words.first, articles.contains(VoiceCommandParser.normalize(first)) {
            words.removeFirst()
        }
        return words.joined(separator: " ").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let numberWords: [String: Int] = [
        "um": 1, "uma": 1, "one": 1,
        "dois": 2, "duas": 2, "two": 2,
        "tres": 3, "three": 3,
        "quatro": 4, "four": 4,
        "cinco": 5, "five": 5,
        "seis": 6, "six": 6,
        "sete": 7, "seven": 7,
        "oito": 8, "eight": 8,
        "nove": 9, "nine": 9,
        "dez": 10, "ten": 10
    ]

    static func firstNumber(in normalized: String) -> Int? {
        for word in normalized.split(separator: " ") {
            if let digit = Int(word) {
                return digit
            }
            if let mapped = numberWords[String(word)] {
                return mapped
            }
        }
        return nil
    }

    private static func parseBrightnessAction(_ normalized: String) -> BrightnessAction? {
        let terms = ["brilho", "luminosidade", "brightness", "claridade", "luz da tela", "luz do monitor", "tela mais clara", "tela mais escura"]
        let mentionsScreen = normalized.contains("tela") || normalized.contains("monitor") || normalized.contains("screen")
        guard terms.contains(where: { normalized.contains($0) }) || mentionsScreen else { return nil }

        let upSignals = ["aument", "sub", "mais alto", "mais claro", "mais clara", "clare", "brighter", "up", "sobe", "suba"]
        let downSignals = ["diminu", "abaix", "menos", "mais baixo", "mais escuro", "mais escura", "escurec", "darker", "down", "desce", "desça"]

        if upSignals.contains(where: { normalized.contains($0) }) { return .up }
        if downSignals.contains(where: { normalized.contains($0) }) { return .down }
        return nil
    }

    private static func parseVolumeAction(_ normalized: String) -> VolumeAction? {
        if containsAny(normalized, ["mute", "silencie", "silenciar", "sem som", "mutar", "desligue o som", "desliga o som"]) {
            return .mute
        }

        let exactUp = [
            "aumente o volume", "aumentar volume", "volume mais alto", "volume up", "louder",
            "suba o volume", "sobe o volume", "coloque mais volume", "mais volume", "aumenta o som"
        ]
        let exactDown = [
            "diminua o volume", "diminuir volume", "abaixe o volume", "volume mais baixo", "volume down", "quieter",
            "baixe o volume", "menos volume", "abaixa o som", "diminui o som"
        ]
        if containsAny(normalized, exactUp) { return .up }
        if containsAny(normalized, exactDown) { return .down }

        let volumeTerms = ["volume", "som", "audio", "sound"]
        guard volumeTerms.contains(where: { normalized.contains($0) }) else { return nil }

        let upSignals = ["aument", "sub", "mais alto", "louder", "up", "sobe", "suba"]
        let downSignals = ["diminu", "abaix", "menos", "mais baixo", "quieter", "down", "desce", "baix"]
        if upSignals.contains(where: { normalized.contains($0) }) { return .up }
        if downSignals.contains(where: { normalized.contains($0) }) { return .down }
        return nil
    }

    private static func parseTextTransform(_ normalized: String) -> ClipboardTextTransform? {
        let map: [(ClipboardTextTransform, [String])] = [
            (.minifyJSON, ["minifique o json", "minificar json", "minify json", "compactar json", "compacte o json"]),
            (.upperCase, ["maiusculas", "em maiusculas", "uppercase", "upper case", "tudo maiusculo"]),
            (.lowerCase, ["minusculas", "em minusculas", "lowercase", "lower case", "tudo minusculo"]),
            (.base64Encode, ["codificar base64", "encode base64", "em base64", "para base64"]),
            (.base64Decode, ["decodificar base64", "decode base64", "de base64"]),
            (.camelCase, ["camel case", "camelcase", "em camelcase"]),
            (.snakeCase, ["snake case", "snakecase", "em snake case"]),
            (.trimWhitespace, ["trim", "remover espacos", "remova espacos", "tirar espacos"]),
        ]

        for (transform, phrases) in map where containsAny(normalized, phrases) {
            return transform
        }
        return nil
    }

    private static func resolveWebsiteAlias(_ name: String) -> String? {
        let key = normalize(name)
        if let domain = VoiceCommandCatalog.websiteAliases[key] {
            return domain
        }
        for (alias, domain) in VoiceCommandCatalog.websiteAliases where key == alias || key.hasSuffix(" \(alias)") {
            return domain
        }
        return nil
    }
}
