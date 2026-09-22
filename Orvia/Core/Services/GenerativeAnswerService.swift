import AppKit
import Foundation
import FoundationModels

/// Gera toda fala do Orvia via Apple Foundation Models — sem templates fixos.
@MainActor
final class GenerativeAnswerService: ObservableObject {
    enum ModelStatus: Equatable {
        case available
        case downloading
        case appleIntelligenceDisabled
        case deviceNotEligible
        case unavailable
        case unsupportedOS

        var isReady: Bool { self == .available }
    }

    /// Pedido de fala: chat livre do usuário, ou confirmação de ação do Mac.
    enum SpokenRequest {
        /// Fala do usuário enviada direto à IA (com o pre-prompt de identidade).
        case chat(String)
        /// Ação já executada; o modelo só verbaliza o resultado.
        case action(fact: String, success: Bool)
    }

    enum GenerationPhase: Equatable {
        case idle
        case fetchingWeb
        case generating
    }

    @Published private(set) var status: ModelStatus = .unsupportedOS
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var phase: GenerationPhase = .idle

    /// Notifica mudanças de fase (HUD / acessibilidade).
    var onPhaseChange: ((GenerationPhase) -> Void)?

    private let webSnippetSearch = WebSnippetSearchService()
    private var sessionStorage: AnyObject?
    private var sessionUserName: String?
    private var sessionTurnCount = 0

    init() {
        refreshStatus(userName: nil)
    }

    func refreshStatus(userName: String? = nil) {
        guard #available(macOS 26.0, *) else {
            status = .unsupportedOS
            sessionStorage = nil
            return
        }

        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            status = .available
            ensureSession(userName: userName)
        case .unavailable(let reason):
            sessionStorage = nil
            sessionUserName = nil
            sessionTurnCount = 0
            switch reason {
            case .appleIntelligenceNotEnabled:
                status = .appleIntelligenceDisabled
            case .modelNotReady:
                status = .downloading
            case .deviceNotEligible:
                status = .deviceNotEligible
            @unknown default:
                status = .unavailable
            }
        @unknown default:
            sessionStorage = nil
            sessionUserName = nil
            sessionTurnCount = 0
            status = .unavailable
        }
    }

    /// Gera a fala do Orvia para qualquer turno.
    func respond(
        to request: SpokenRequest,
        languageCode: String,
        userName: String?,
        useWebContext: Bool,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        refreshStatus(userName: userName)
        guard status.isReady else {
            setPhase(.idle)
            completion(.failure(GenerativeAnswerError.modelUnavailable(status)))
            return
        }

        switch request {
        case .chat(let text):
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                setPhase(.idle)
                completion(.failure(GenerativeAnswerError.emptyQuestion))
                return
            }
            if useWebContext {
                setPhase(.fetchingWeb)
                webSnippetSearch.fetchSpokenSnippet(query: cleaned) { [weak self] snippet in
                    Task { @MainActor in
                        guard let self else { return }
                        self.setPhase(.generating)
                        await self.generate(
                            promptBody: self.chatPrompt(
                                cleaned,
                                webContext: snippet
                            ),
                            languageCode: languageCode,
                            userName: userName,
                            completion: completion
                        )
                    }
                }
            } else {
                setPhase(.generating)
                Task { @MainActor in
                    await self.generate(
                        promptBody: self.chatPrompt(
                            cleaned,
                            webContext: nil
                        ),
                        languageCode: languageCode,
                        userName: userName,
                        completion: completion
                    )
                }
            }

        case .action(let fact, let success):
            let cleaned = fact.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                setPhase(.idle)
                completion(.failure(GenerativeAnswerError.emptyQuestion))
                return
            }
            setPhase(.generating)
            Task { @MainActor in
                await generate(
                    promptBody: actionPrompt(fact: cleaned, success: success),
                    languageCode: languageCode,
                    userName: userName,
                    completion: completion
                )
            }
        }
    }

    private func setPhase(_ newPhase: GenerationPhase) {
        phase = newPhase
        onPhaseChange?(newPhase)
    }

    func answer(
        question: String,
        languageCode: String,
        useWebContext: Bool,
        userName: String? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        respond(
            to: .chat(question),
            languageCode: languageCode,
            userName: userName,
            useWebContext: useWebContext,
            completion: completion
        )
    }

    func openAppleIntelligenceSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Siri-Settings.extension",
            "x-apple.systempreferences:com.apple.Siri"
        ]
        for raw in candidates {
            if let url = URL(string: raw) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }

    // MARK: - Session

    @available(macOS 26.0, *)
    private func ensureSession(userName: String?) {
        let normalized = userName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if sessionStorage == nil || sessionUserName != normalized {
            sessionStorage = makeSession(userName: normalized)
            sessionUserName = normalized
            sessionTurnCount = 0
        }
    }

    @available(macOS 26.0, *)
    private func makeSession(userName: String?) -> LanguageModelSession {
        LanguageModelSession(instructions: OrviaAssistantIdentity.systemInstructions(userName: userName))
    }

    // MARK: - Prompt bodies

    private func chatPrompt(_ userText: String, webContext: String?) -> String {
        var body = """
            Vá DIRETO à resposta. Sem saudação, sem "e aí", sem "oi", sem começar pelo nome do usuário.
            Só cumprimente se a mensagem do usuário for APENAS um oi/e aí — senão, responde o que foi perguntado.
            Você é o Orvia (só Orvia — nunca outro nome). Português brasileiro jovem, humanizado, tech, natural pra TTS.
            Se for papo casual, converse de verdade: reaja, tenha personalidade, pode perguntar de volta.
            Não vire tutorial do app nem invente nomes/ferramentas.
            Usuário: \(userText)
            """
        if let webContext, !webContext.isEmpty {
            body += """


            Contexto recente da internet (pode estar incompleto; use para fatos atuais):
            \(webContext)
            """
        }
        return body
    }

    private func actionPrompt(fact: String, success: Bool) -> String {
        let tone = success
            ? "O fato abaixo já aconteceu com sucesso."
            : "O fato abaixo descreve uma falha."
        return """
            \(tone)
            Fato: \(fact)

            Responda SOMENTE com a frase que o Orvia deve falar em voz alta.
            Tom: português brasileiro jovem, gíria leve e natural (fechou, suave, deu ruim, top…).
            Regras: uma frase curta; use o fato; sem cumprimento no começo; \
            não repita estas regras; não diga "fato", "sucesso", "falha" nem instruções.
            """
    }

    // MARK: - Generate

    private func generate(
        promptBody: String,
        languageCode: String,
        userName: String?,
        completion: @escaping (Result<String, Error>) -> Void
    ) async {
        guard #available(macOS 26.0, *) else {
            completion(.failure(GenerativeAnswerError.modelUnavailable(.unsupportedOS)))
            return
        }

        refreshStatus(userName: userName)
        guard let session = sessionStorage as? LanguageModelSession else {
            completion(.failure(GenerativeAnswerError.modelUnavailable(status)))
            return
        }

        let languageHint = languageCode.lowercased().hasPrefix("pt")
            ? "Responda como o Orvia: direto ao ponto, sem saudação. Português BR jovem, humanizado e tech."
            : "Answer as Orvia: direct, no greeting. Casual human tech-savvy English."

        let prompt = """
            \(languageHint)
            \(promptBody)
            """

        do {
            let response = try await session.respond(to: prompt)
            let text = Self.sanitizeForSpeech(response.content, userName: userName)
            setPhase(.idle)
            guard !text.isEmpty, !Self.looksLikePromptLeak(text) else {
                completion(.failure(GenerativeAnswerError.emptyResponse))
                return
            }
            sessionTurnCount += 1
            lastErrorMessage = nil
            completion(.success(text))
        } catch {
            setPhase(.idle)
            lastErrorMessage = error.localizedDescription
            sessionStorage = makeSession(userName: userName?.trimmingCharacters(in: .whitespacesAndNewlines))
            sessionUserName = userName?.trimmingCharacters(in: .whitespacesAndNewlines)
            sessionTurnCount = 0
            completion(.failure(error))
        }
    }

    private static func sanitizeForSpeech(_ text: String, userName: String? = nil) -> String {
        var cleaned = text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        cleaned = stripEmojis(from: cleaned)
        cleaned = rewriteWrongAssistantNames(in: cleaned)
        cleaned = stripLeadingGreeting(from: cleaned, userName: userName)

        // Remove aspas envolventes que o modelo às vezes coloca.
        if (cleaned.hasPrefix("\"") && cleaned.hasSuffix("\""))
            || (cleaned.hasPrefix("“") && cleaned.hasSuffix("”"))
            || (cleaned.hasPrefix("'") && cleaned.hasSuffix("'")) {
            cleaned = String(cleaned.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        cleaned = cleaned
            .components(separatedBy: .newlines)
            .map { line in
                var value = line.trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("- ") {
                    value = String(value.dropFirst(2))
                }
                return value
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // Permite explicações mais longas; corta só abusos extremos.
        let maxCharacters = 1400
        if cleaned.count > maxCharacters {
            let sentences = KnowledgeService.splitSentences(cleaned)
            if sentences.count > 1 {
                var assembled = ""
                for sentence in sentences {
                    let next = assembled.isEmpty ? sentence : assembled + " " + sentence
                    if next.count > maxCharacters { break }
                    assembled = next
                }
                cleaned = assembled.isEmpty ? String(cleaned.prefix(maxCharacters)) : assembled
            } else {
                cleaned = String(cleaned.prefix(maxCharacters))
            }
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove saudações automáticas no início ("E aí, Richard Farias, suave?", etc.).
    private static func stripLeadingGreeting(from text: String, userName: String?) -> String {
        let folded = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()

        var prefixes: [String] = [
            "e ai, ", "e ai ", "eai, ", "eai ",
            "oi, ", "oi ", "ola, ", "ola ",
            "fala, ", "fala ", "salve, ", "salve ",
            "hey, ", "hey ", "hi, ", "hi ",
            "bom dia, ", "bom dia ", "boa tarde, ", "boa tarde ", "boa noite, ", "boa noite "
        ]

        if let rawName = userName?.trimmingCharacters(in: .whitespacesAndNewlines), !rawName.isEmpty {
            let name = rawName
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
                .lowercased()
            prefixes.insert(contentsOf: [
                "e ai, \(name), suave? ",
                "e ai, \(name), suave ",
                "e ai, \(name)? ",
                "e ai, \(name)! ",
                "e ai, \(name). ",
                "e ai, \(name), ",
                "e ai, \(name) ",
                "e ai \(name), suave? ",
                "e ai \(name), ",
                "e ai \(name) ",
                "oi, \(name), ",
                "oi, \(name) ",
                "oi \(name), ",
                "oi \(name) ",
                "ola, \(name), ",
                "ola, \(name) "
            ], at: 0)
        }

        prefixes.append(contentsOf: [
            "e ai, suave? ", "e ai, suave ", "e ai suave? ", "e ai suave "
        ])

        for prefix in prefixes {
            guard folded.hasPrefix(prefix) else { continue }
            // Mapeia o prefixo dobrado de volta ao texto original pelo mesmo número de palavras/pontuação.
            // Como folding só remove diacríticos, o count de caracteres costuma bater; se não, corta pelo prefixo no folded.
            let originalPrefixCount = prefix.count
            guard text.count > originalPrefixCount else { continue }
            // Conta no texto original usando o mesmo intervalo do folded quando os lengths coincidem.
            if text.count == folded.count {
                let stripped = String(text.dropFirst(prefix.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,!?.:;"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !stripped.isEmpty { return stripped }
            } else {
                // Fallback: remove pelo regex no texto original.
                break
            }
        }

        // Regex no texto original (com e sem acento).
        let pattern = #"^(?:E\s*a[ií]|Oi|Ol[aá]|Fala|Salve|Hey|Hi|Hello|Bom\s+dia|Boa\s+tarde|Boa\s+noite)(?:\s*[,!]?\s*[A-Za-zÀ-ÿ]+(?:\s+[A-Za-zÀ-ÿ]+){0,3})?(?:\s*[,!]?\s*(?:suave|beleza|firmeza|tudo\s+bem|tudo\s+certo))?\s*[,!?.:;]*\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.range.length > 0,
              match.range.length < text.count,
              let swiftRange = Range(match.range, in: text) else {
            return text
        }
        let stripped = String(text[swiftRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? text : stripped
    }

    private static func stripEmojis(from text: String) -> String {
        text.unicodeScalars
            .filter { scalar in
                let v = scalar.value
                // Faixas comuns de emoji / pictográficos
                let isEmoji =
                    (v >= 0x1F300 && v <= 0x1FAFF) ||
                    (v >= 0x2600 && v <= 0x27BF) ||
                    (v >= 0xFE00 && v <= 0xFE0F) ||
                    (v >= 0x1F1E6 && v <= 0x1F1FF) ||
                    v == 0x200D ||
                    v == 0x3030 ||
                    v == 0x00A9 ||
                    v == 0x00AE
                return !isEmoji
            }
            .map(String.init)
            .joined()
            .replacingOccurrences(of: "  ", with: " ")
    }

    /// Corrige alucinações de nome (ex.: "Sniper") para Orvia.
    private static func rewriteWrongAssistantNames(in text: String) -> String {
        let wrongNames = ["Sniper", "sniper", "SNIPER", "Jarvis", "jarvis"]
        var result = text
        for name in wrongNames {
            result = result.replacingOccurrences(of: name, with: OrviaAssistantIdentity.assistantName)
        }
        return result
    }

    /// Detecta quando o modelo ecoa instruções do prompt em vez de falar.
    private static func looksLikePromptLeak(_ text: String) -> Bool {
        let normalized = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()

        let markers = [
            "confirme em voz alta",
            "nao explique o produto",
            "nao explique o app",
            "uma frase curta e natural",
            "responda somente com a frase",
            "nao repita estas regras",
            "nao repita estas instrucoes",
            "sua fala:",
            "tarefa:",
            "acao do orvia concluida",
            "sou o sniper",
            "o sniper e a ferramenta"
        ]
        return markers.contains { normalized.contains($0) }
    }
}

enum GenerativeAnswerError: LocalizedError {
    case emptyQuestion
    case emptyResponse
    case modelUnavailable(GenerativeAnswerService.ModelStatus)

    var errorDescription: String? {
        switch self {
        case .emptyQuestion:
            return "Pedido vazio."
        case .emptyResponse:
            return "O modelo não retornou texto."
        case .modelUnavailable(let status):
            switch status {
            case .available:
                return "Modelo indisponível."
            case .downloading:
                return "O modelo ainda está baixando."
            case .appleIntelligenceDisabled:
                return "Ative o Apple Intelligence nas Ajustes do Sistema."
            case .deviceNotEligible:
                return "Este Mac não é compatível com Apple Intelligence."
            case .unavailable:
                return "Modelo generativo indisponível no momento."
            case .unsupportedOS:
                return "Requer macOS 26 ou superior."
            }
        }
    }
}
