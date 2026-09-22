import Foundation

/// Normaliza perguntas faladas (STT) para melhorar busca e intenção.
enum QuestionPreprocessor {
    /// Perguntas que não devem receber um palpite baseado apenas no modelo local.
    static func requiresCurrentInformation(_ rawText: String) -> Bool {
        let normalized = VoiceCommandParser.normalize(rawText)
        let words = Set(normalized.split(separator: " ").map(String.init))
        let currentSubjects: Set<String> = [
            "noticia", "noticias", "news", "preco", "precos", "price", "prices",
            "cotacao", "exchange", "dolar", "euro", "bitcoin", "bolsa",
            "presidente", "president", "ceo", "eleicao", "election",
            "placar", "score", "resultado", "resultados", "vencedor", "winner",
            "clima", "weather", "previsao", "forecast", "temperatura"
        ]
        if !words.isDisjoint(with: currentSubjects) { return true }

        let freshnessWords: Set<String> = [
            "hoje", "agora", "atualmente", "recente", "recentes", "ultima", "ultimo",
            "today", "now", "currently", "latest", "recent"
        ]
        let factualOpeners: Set<String> = [
            "quem", "qual", "quais", "quando", "onde", "quanto", "quantos", "quantas",
            "who", "what", "when", "where", "how"
        ]
        return !words.isDisjoint(with: freshnessWords)
            && !words.isDisjoint(with: factualOpeners)
    }

    /// Remove preenchimentos de fala e retorna a pergunta limpa, ou nil se não for pergunta.
    static func prepare(_ rawText: String) -> String? {
        var result = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return nil }

        var normalized = VoiceCommandParser.normalize(result)
        normalized = stripWakeWordRemnants(normalized)
        normalized = stripLeadingFillers(normalized)
        normalized = applySpokenCorrections(normalized)

        guard isKnowledgeQuery(normalized) else { return nil }

        result = stripWakeWordFromOriginal(result)
        result = stripLeadingFillersFromOriginal(result)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Detecção

    static func isKnowledgeQuery(_ normalized: String) -> Bool {
        if normalized.hasSuffix("?") { return true }
        if questionPrefixMatch(normalized) { return true }
        if questionSignalMatch(normalized) { return true }
        if implicitFactualQuery(normalized) { return true }
        return false
    }

    private static let questionPrefixes = [
        "quem ", "qual ", "quais ", "quando ", "onde ", "por que ", "porque ",
        "o que ", "quanto ", "quantos ", "quantas ", "como ",
        "me fale sobre ", "me fala sobre ", "me explica ", "me explicar ",
        "me conta ", "me contar ", "fale sobre ", "fala sobre ",
        "who ", "what ", "when ", "where ", "why ", "how ", "tell me about "
    ]

    private static let questionSignals = [
        "quem e o", "quem e a", "quem foi", "quem sao", "quem inventou", "quem criou", "quem descobriu",
        "o que e", "o que sao", "o que significa", "o que faz",
        "qual e o", "qual e a", "qual o", "qual a", "quais sao",
        "quando foi", "quando e", "quando nasceu", "quando morreu",
        "onde fica", "onde e", "onde nasceu", "onde fica o", "onde fica a",
        "quantos anos", "quantos habitantes", "quantas pessoas", "quanto custa", "quanto vale",
        "como funciona", "como e", "como se", "como fazer",
        "sabe quem", "sabe qual", "sabe o que", "sabe quando", "sabe onde", "sabe me dizer",
        "pode me dizer", "pode me falar", "queria saber", "quero saber", "gostaria de saber",
        "me diz", "me diga", "me fala", "me explica",
        "who is", "who was", "what is", "when was", "where is", "how many", "how does"
    ]

    private static let implicitPatterns = [
        "capital de", "capital do", "capital da",
        "presidente de", "presidente do", "presidente da",
        "populacao de", "populacao do", "habitantes de", "habitantes do",
        "idade de", "altura de", "peso de",
        "significado de", "definicao de", "definicao do"
    ]

    private static let greetings: Set<String> = [
        "bom dia", "boa tarde", "boa noite", "oi", "ola", "e ai", "tudo bem",
        "hello", "hi", "good morning", "good night"
    ]

    private static let commandVerbs: Set<String> = [
        "abra", "abre", "abrir", "open", "copie", "copia", "copiar", "copy",
        "cole", "cola", "colar", "paste", "tire", "print", "screenshot",
        "limpe", "limpar", "clear", "feche", "fechar", "close", "digite", "escreva",
        "favorite", "favoritar", "salve", "salvar", "pesquise", "pesquisar", "search",
        "pausar", "pause", "retomar", "resume", "formate", "format"
    ]

    private static func questionPrefixMatch(_ normalized: String) -> Bool {
        questionPrefixes.contains { normalized.hasPrefix($0) }
    }

    private static func questionSignalMatch(_ normalized: String) -> Bool {
        questionSignals.contains { normalized.contains($0) }
    }

    private static func implicitFactualQuery(_ normalized: String) -> Bool {
        guard !greetings.contains(normalized) else { return false }
        let words = normalized.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return false }

        let first = words[0]
        if commandVerbs.contains(first) { return false }

        return implicitPatterns.contains { normalized.contains($0) }
    }

    // MARK: - Limpeza

    private static let leadingFillers = [
        "por favor", "por favor,", "ei", "ei,", "olha", "entao", "então",
        "eu quero saber", "queria saber", "gostaria de saber", "preciso saber",
        "sabe me dizer", "pode me dizer", "pode me falar", "me diz", "me diga",
        "me fala", "me fale", "me contar", "me conta",
        "quero saber", "queria saber se", "gostaria de saber se",
        "i want to know", "can you tell me", "please tell me", "tell me"
    ]

    private static func stripLeadingFillers(_ text: String) -> String {
        var result = text
        var changed = true
        while changed {
            changed = false
            for filler in leadingFillers.sorted(by: { $0.count > $1.count }) {
                if result.hasPrefix(filler + " ") {
                    result = String(result.dropFirst(filler.count + 1))
                    changed = true
                    break
                }
                if result == filler {
                    result = ""
                    changed = true
                    break
                }
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripWakeWordFromOriginal(_ text: String) -> String {
        let folded = VoiceCommandParser.normalize(text)
        for wake in wakeWordVariants() where !wake.isEmpty {
            if folded.hasPrefix(wake + " ") {
                let offset = wake.count + 1
                guard let start = text.index(text.startIndex, offsetBy: offset, limitedBy: text.endIndex) else { continue }
                return String(text[start...])
            }
            if folded == wake { return "" }
        }
        return text
    }

    private static func stripLeadingFillersFromOriginal(_ text: String) -> String {
        var result = text
        var folded = VoiceCommandParser.normalize(result)
        var changed = true

        while changed {
            changed = false
            for filler in leadingFillers.sorted(by: { $0.count > $1.count }) {
                if folded.hasPrefix(filler + " ") {
                    let offset = filler.count + 1
                    guard let start = result.index(result.startIndex, offsetBy: offset, limitedBy: result.endIndex) else { continue }
                    result = String(result[start...])
                    folded = VoiceCommandParser.normalize(result)
                    changed = true
                    break
                }
                if folded == filler {
                    result = ""
                    folded = ""
                    changed = true
                    break
                }
            }
        }
        return result
    }

    private static func stripWakeWordRemnants(_ text: String) -> String {
        var result = text
        for wake in wakeWordVariants() where !wake.isEmpty {
            if result.hasPrefix(wake + " ") {
                result = String(result.dropFirst(wake.count + 1))
            } else if result == wake {
                result = ""
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func wakeWordVariants() -> [String] {
        ["orvia", "or via", "orvya"]
    }

    /// Corrige termos frequentemente errados pelo reconhecimento de voz.
    private static func applySpokenCorrections(_ text: String) -> String {
        var result = text
        let corrections: [(String, String)] = [
            ("braseal", "brasil"), ("brazil", "brasil"), ("brasilero", "brasileiro"),
            ("presidencia", "presidente"), ("presidenti", "presidente"),
            ("fotocintese", "fotossintese"), ("fotosintese", "fotossintese"),
            ("capital brasil", "capital do brasil"),
            ("presidente brasil", "presidente do brasil"),
            ("eua", "estados unidos"), ("usa", "estados unidos"),
            ("reino unido", "reino unido"), ("inglaterra", "inglaterra")
        ]
        for (wrong, right) in corrections {
            result = result.replacingOccurrences(of: wrong, with: right)
        }
        return result
    }
}
