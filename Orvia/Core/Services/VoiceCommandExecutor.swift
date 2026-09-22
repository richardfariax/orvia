import AppKit
import Foundation

/// Conecta comandos de voz às ações do app. Toda fala passa pelo modelo generativo.
@MainActor
final class VoiceCommandExecutor {
    enum FollowUp {
        /// Continuar a conversa (Orvia fez uma pergunta).
        case awaitReply
        case webSearch(String)
        case openURL(String)
    }

    static let developerName = DeveloperProfileCatalog.displayName
    static let developerLinkedInURL = DeveloperProfileCatalog.linkedInURL

    struct Feedback {
        let message: String
        let success: Bool
        let followUp: FollowUp?

        init(message: String, success: Bool, followUp: FollowUp? = nil) {
            self.message = message
            self.success = success
            self.followUp = followUp
        }
    }

    private let knowledgeService = KnowledgeService()
    private let generativeAnswerService = GenerativeAnswerService()
    private let settings: AppSettings
    private let panelViewModel: ClipboardPanelViewModel
    private let pasteService: PasteService
    private let screenshotService: ScreenshotService
    private let screenAnalysisService: ScreenAnalysisService
    private let targetApplicationProvider: () -> NSRunningApplication?
    private let openPanel: () -> Void
    private let closePanel: () -> Void
    private let openSettings: () -> Void
    private let hideOverlayForCapture: () -> Void

    /// Atualiza o HUD durante busca na web / geração.
    var onGenerationPhaseChange: ((GenerativeAnswerService.GenerationPhase) -> Void)?

    init(
        settings: AppSettings,
        panelViewModel: ClipboardPanelViewModel,
        pasteService: PasteService,
        screenshotService: ScreenshotService,
        screenAnalysisService: ScreenAnalysisService,
        targetApplicationProvider: @escaping () -> NSRunningApplication?,
        openPanel: @escaping () -> Void,
        closePanel: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        hideOverlayForCapture: @escaping () -> Void
    ) {
        self.settings = settings
        self.panelViewModel = panelViewModel
        self.pasteService = pasteService
        self.screenshotService = screenshotService
        self.screenAnalysisService = screenAnalysisService
        self.targetApplicationProvider = targetApplicationProvider
        self.openPanel = openPanel
        self.closePanel = closePanel
        self.openSettings = openSettings
        self.hideOverlayForCapture = hideOverlayForCapture
        generativeAnswerService.onPhaseChange = { [weak self] phase in
            self?.onGenerationPhaseChange?(phase)
        }
    }

    func execute(rawText: String, completion: @escaping (Feedback) -> Void) {
        guard let command = VoiceCommandParser.parse(rawText) else {
            chatWithAI(rawText, completion: completion)
            return
        }

        switch command {
        case .openApp(let name):
            let opened = openApplication(named: name)
            speakAction(
                opened ? "Abriu o app \(name)." : "Não encontrou o app chamado \(name).",
                success: opened,
                completion: completion
            )

        case .screenshotFull:
            screenshotService.capture(.fullScreen) { [weak self] success in
                guard let self else { return }
                self.speakAction(
                    success ? "Print da tela inteira salvo no histórico." : "Falhou ao capturar a tela.",
                    success: success,
                    completion: completion
                )
            }

        case .screenshotArea:
            screenshotService.capture(.interactiveArea) { [weak self] success in
                guard let self else { return }
                self.speakAction(
                    success ? "Captura de área salva no histórico." : "Captura de área cancelada.",
                    success: success,
                    completion: completion
                )
            }

        case .analyzeScreen:
            let languageCode = settings.text(ptBR: "pt", en: "en")
            screenAnalysisService.describeVisibleScreen(
                languageCode: languageCode,
                onPrepareCapture: hideOverlayForCapture
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let description):
                    self.speakAction(
                        "Conteúdo lido da tela: \(description)",
                        success: true,
                        completion: completion
                    )
                case .failure(ScreenAnalysisError.permissionDenied):
                    self.speakAction(
                        "Não conseguiu capturar a tela por falta de permissão de Gravação de Tela. Peça para conferir nos Ajustes e reabrir o app se precisar.",
                        success: false,
                        completion: completion
                    )
                case .failure(ScreenAnalysisError.captureFailed):
                    self.speakAction("Não conseguiu capturar a tela.", success: false, completion: completion)
                case .failure:
                    self.speakAction("Não conseguiu analisar a tela.", success: false, completion: completion)
                }
            }

        case .openPanel:
            openPanel()
            speakAction("Abriu o painel do Orvia.", success: true, completion: completion)

        case .closePanel:
            closePanel()
            speakAction("Fechou o painel do Orvia.", success: true, completion: completion)

        case .copyItem(let index):
            panelViewModel.refresh()
            guard let item = panelViewModel.item(atDisplayIndex: index) else {
                speakItemMissing(index, completion: completion)
                return
            }
            let copied = panelViewModel.copyToPasteboard(item: item)
            speakAction(
                copied ? "Copiou o item \(index) do histórico." : "Falhou ao copiar o item \(index).",
                success: copied,
                completion: completion
            )

        case .pasteItem(let index):
            panelViewModel.refresh()
            guard let item = panelViewModel.item(atDisplayIndex: index) else {
                speakItemMissing(index, completion: completion)
                return
            }
            panelViewModel.paste(item: item, targetApplication: targetApplicationProvider())
            speakAction("Colando o item \(index) do histórico.", success: true, completion: completion)

        case .pasteLast:
            panelViewModel.refresh()
            guard panelViewModel.mostRecentItem() != nil else {
                speakAction("O histórico está vazio.", success: false, completion: completion)
                return
            }
            if let item = panelViewModel.mostRecentItem() {
                panelViewModel.paste(item: item, targetApplication: targetApplicationProvider())
            }
            speakAction("Colando o último item do histórico.", success: true, completion: completion)

        case .readLastItem:
            panelViewModel.refresh()
            guard let item = panelViewModel.mostRecentItem() else {
                speakAction("O histórico está vazio.", success: false, completion: completion)
                return
            }
            speakAction(
                "Último item copiado: \(itemSpeechContext(item))",
                success: true,
                completion: completion
            )

        case .copyLastItem:
            panelViewModel.refresh()
            guard let item = panelViewModel.mostRecentItem() else {
                speakAction("O histórico está vazio.", success: false, completion: completion)
                return
            }
            let copied = panelViewModel.copyToPasteboard(item: item)
            speakAction(
                copied ? "Copiou o último item do histórico." : "Falhou ao copiar o último item.",
                success: copied,
                completion: completion
            )

        case .favoriteItem(let index):
            panelViewModel.refresh()
            guard let item = panelViewModel.item(atDisplayIndex: index) else {
                speakItemMissing(index, completion: completion)
                return
            }
            panelViewModel.toggleFavorite(itemID: item.id)
            speakAction("Favoritou o item \(index).", success: true, completion: completion)

        case .deleteItem(let index):
            panelViewModel.refresh()
            guard let item = panelViewModel.item(atDisplayIndex: index) else {
                speakItemMissing(index, completion: completion)
                return
            }
            panelViewModel.delete(itemID: item.id)
            speakAction("Apagou o item \(index) do histórico.", success: true, completion: completion)

        case .pinItem(let index):
            panelViewModel.refresh()
            guard let item = panelViewModel.item(atDisplayIndex: index) else {
                speakItemMissing(index, completion: completion)
                return
            }
            let wasPinned = item.isPinned
            panelViewModel.togglePin(itemID: item.id)
            speakAction(
                wasPinned ? "Desafixou o item \(index)." : "Fixou o item \(index).",
                success: true,
                completion: completion
            )

        case .historyCount:
            panelViewModel.refresh()
            let count = panelViewModel.itemCount
            let stack = panelViewModel.pasteStack.count
            let fact = stack > 0
                ? "Há \(count) itens no histórico e \(stack) na pilha de colagem."
                : "Há \(count) itens no histórico."
            speakAction(fact, success: true, completion: completion)

        case .clearHistory:
            panelViewModel.clearAll()
            speakAction("Limpou o histórico da área de transferência.", success: true, completion: completion)

        case .dictate(let text):
            pasteService.paste(text: text, targetApplication: targetApplicationProvider())
            speakAction("Digitando o texto ditado.", success: true, completion: completion)

        case .formatJSONLast:
            panelViewModel.refresh()
            let ok = panelViewModel.formatMostRecentJSON()
            speakAction(
                ok ? "Formatou o JSON do último item e copiou." : "O último item não é um JSON válido.",
                success: ok,
                completion: completion
            )

        case .transformLast(let transform):
            panelViewModel.refresh()
            let ok = panelViewModel.transformMostRecent(transform)
            let name = transform.title(for: settings.language)
            speakAction(
                ok ? "Aplicou \(name) no último item e copiou." : "Não conseguiu aplicar \(name) no último item.",
                success: ok,
                completion: completion
            )

        case .saveSnippet(let name):
            panelViewModel.refresh()
            let saved = panelViewModel.saveMostRecentAsSnippet(named: name)
            speakAction(
                saved ? "Salvou o snippet chamado \(name)." : "Não havia nada para salvar como snippet.",
                success: saved,
                completion: completion
            )

        case .pasteSnippet(let name):
            panelViewModel.refresh()
            guard let item = panelViewModel.snippet(named: name) else {
                speakAction("Não encontrou o snippet \(name).", success: false, completion: completion)
                return
            }
            panelViewModel.paste(item: item, targetApplication: targetApplicationProvider())
            speakAction("Colando o snippet \(name).", success: true, completion: completion)

        case .listSnippets:
            panelViewModel.refresh()
            let names = panelViewModel.snippetNames()
            if names.isEmpty {
                speakAction("Ainda não há snippets salvos.", success: false, completion: completion)
            } else {
                speakAction("Snippets salvos: \(names.joined(separator: ", ")).", success: true, completion: completion)
            }

        case .stackAdd(let index):
            panelViewModel.refresh()
            guard let item = panelViewModel.item(atDisplayIndex: index) else {
                speakItemMissing(index, completion: completion)
                return
            }
            panelViewModel.addToStack(itemID: item.id)
            speakAction(
                "Adicionou o item \(index) à pilha. A pilha agora tem \(panelViewModel.pasteStack.count) itens.",
                success: true,
                completion: completion
            )

        case .stackPasteNext:
            let pasted = panelViewModel.pasteNextFromStack(targetApplication: targetApplicationProvider())
            speakAction(
                pasted
                    ? "Colou o próximo da pilha. Restam \(panelViewModel.pasteStack.count)."
                    : "A pilha de colagem está vazia.",
                success: pasted,
                completion: completion
            )

        case .stackClear:
            panelViewModel.clearStack()
            speakAction("Limpou a pilha de colagem.", success: true, completion: completion)

        case .pauseMonitoring:
            settings.pauseMonitoring = true
            speakAction("Pausou o monitoramento da área de transferência.", success: true, completion: completion)

        case .resumeMonitoring:
            settings.pauseMonitoring = false
            speakAction("Retomou o monitoramento da área de transferência.", success: true, completion: completion)

        case .currentTime:
            let formatter = DateFormatter()
            formatter.locale = currentLocale()
            formatter.timeStyle = .short
            let time = formatter.string(from: Date())
            speakAction("Agora são \(time).", success: true, completion: completion)

        case .currentDate:
            let formatter = DateFormatter()
            formatter.locale = currentLocale()
            formatter.dateStyle = .full
            let date = formatter.string(from: Date())
            speakAction("Hoje é \(date).", success: true, completion: completion)

        case .dayOfWeek:
            let formatter = DateFormatter()
            formatter.locale = currentLocale()
            formatter.dateFormat = "EEEE"
            let day = formatter.string(from: Date())
            speakAction("Hoje é \(day).", success: true, completion: completion)

        case .weather:
            fetchWeather(completion: completion)

        case .openWebsite(let site):
            if let url = websiteURL(from: site) {
                NSWorkspace.shared.open(url)
                speakAction("Abrindo o site \(url.host ?? site).", success: true, completion: completion)
            } else {
                speakAction("Não conseguiu montar o endereço \(site).", success: false, completion: completion)
            }

        case .setUserName(let name):
            settings.userName = name
            speakAction("Guardou o nome do usuário como \(name).", success: true, completion: completion)

        case .openDeveloperProfile:
            if let url = URL(string: Self.developerLinkedInURL) {
                NSWorkspace.shared.open(url)
            }
            speakAction(
                "Abrindo o LinkedIn de \(Self.developerName).",
                success: true,
                completion: completion
            )

        case .openSettings:
            openSettings()
            speakAction("Abrindo as configurações do Orvia.", success: true, completion: completion)

        case .setVoiceEnabled(let enabled):
            settings.voiceControlEnabled = enabled
            speakAction(
                enabled ? "Ativou os comandos de voz." : "Desativou os comandos de voz.",
                success: true,
                completion: completion
            )

        case .lockScreen:
            runShellCommand("/usr/bin/pmset", arguments: ["displaysleepnow"])
            speakAction("Bloqueou a tela.", success: true, completion: completion)

        case .openSpotlight:
            SystemKeySimulator.openSpotlight()
            speakAction("Abrindo o Spotlight.", success: true, completion: completion)

        case .volumeAdjust(let action):
            adjustVolume(action)
            let fact: String
            switch action {
            case .up: fact = "Aumentou o volume."
            case .down: fact = "Diminuiu o volume."
            case .mute: fact = "Silenciou o som."
            }
            speakAction(fact, success: true, completion: completion)

        case .brightnessAdjust(let action):
            adjustBrightness(action)
            let fact: String
            switch action {
            case .up: fact = "Aumentou o brilho da tela."
            case .down: fact = "Diminuiu o brilho da tela."
            }
            speakAction(fact, success: true, completion: completion)

        case .openFolder(let folder):
            NSWorkspace.shared.open(folder.url)
            speakAction(
                "Abrindo a pasta \(folder.spokenName(pt: usesPortuguese)).",
                success: true,
                completion: completion
            )

        case .searchHistory(let query):
            panelViewModel.searchText = query
            panelViewModel.setFilter(.all)
            openPanel()
            speakAction("Buscando \"\(query)\" no histórico e abrindo o painel.", success: true, completion: completion)

        case .showFilter(let filter):
            panelViewModel.setFilter(filter)
            openPanel()
            speakAction(
                "Mostrando o filtro \(filter.title(for: settings.language)) no painel.",
                success: true,
                completion: completion
            )

        case .calculate(let result):
            speakAction("O resultado do cálculo é \(result).", success: true, completion: completion)

        case .webSearch(let query):
            performWebSearch(query, completion: completion)
        }
    }

    func handleFollowUpResponse(_ followUp: FollowUp, answer: String, completion: @escaping (Feedback) -> Void) {
        let cleaned = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            speakAction("Não entendeu a resposta.", success: false, completion: completion)
            return
        }

        switch followUp {
        case .awaitReply:
            execute(rawText: cleaned, completion: completion)

        case .webSearch(let query):
            if isNegativeReply(cleaned) {
                speakAction("O usuário recusou a oferta anterior.", success: true, completion: completion)
            } else if isAffirmativeReply(cleaned) {
                chatWithAI(query, completion: completion)
            } else {
                execute(rawText: cleaned, completion: completion)
            }

        case .openURL(let urlString):
            if isNegativeReply(cleaned) {
                speakAction("O usuário recusou a oferta anterior.", success: true, completion: completion)
            } else if isAffirmativeReply(cleaned) {
                if let url = URL(string: urlString) {
                    NSWorkspace.shared.open(url)
                    speakAction("Abrindo o link pedido.", success: true, completion: completion)
                } else {
                    speakAction("Não conseguiu abrir o link.", success: false, completion: completion)
                }
            } else {
                execute(rawText: cleaned, completion: completion)
            }
        }
    }

    private func isNegativeReply(_ answer: String) -> Bool {
        let normalized = VoiceCommandParser.normalize(answer)
        if normalized == "no" { return true }
        let words = Set(normalized.split(separator: " ").map(String.init))
        let negatives: Set<String> = ["nao", "nope", "cancela", "deixa", "esquece"]
        return !words.isDisjoint(with: negatives)
    }

    private func isAffirmativeReply(_ answer: String) -> Bool {
        let normalized = VoiceCommandParser.normalize(answer)
        let words = Set(normalized.split(separator: " ").map(String.init))
        let affirmatives: Set<String> = ["sim", "pode", "claro", "quero", "manda", "vai", "bora", "yes", "sure", "yep", "ok", "please"]
        return !words.isDisjoint(with: affirmatives)
    }

    // MARK: - Fala generativa

    private func speakAction(
        _ fact: String,
        success: Bool,
        followUp: FollowUp? = nil,
        completion: @escaping (Feedback) -> Void
    ) {
        respond(.action(fact: fact, success: success), success: success, followUp: followUp, useWeb: false, completion: completion)
    }

    /// Único caminho conversacional: a fala do usuário vai direto para a IA com o pre-prompt de identidade.
    private func chatWithAI(_ userText: String, completion: @escaping (Feedback) -> Void) {
        let cleaned = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            speakAction("Não entendeu o que foi dito.", success: false, completion: completion)
            return
        }
        let useWeb = settings.generativeUseWebContext && QuestionPreprocessor.prepare(cleaned) != nil
        respond(.chat(cleaned), success: true, followUp: nil, useWeb: useWeb, completion: completion)
    }

    private func respond(
        _ request: GenerativeAnswerService.SpokenRequest,
        success: Bool,
        followUp: FollowUp?,
        useWeb: Bool,
        completion: @escaping (Feedback) -> Void
    ) {
        let languageCode = settings.text(ptBR: "pt", en: "en")
        let userName = settings.userName.isEmpty ? nil : settings.userName
        let fallbackFact = fallbackText(for: request)

        guard settings.generativeAnswersEnabled else {
            completion(Feedback(message: sanitizeFallback(fallbackFact), success: success, followUp: followUp))
            return
        }

        generativeAnswerService.refreshStatus(userName: userName)
        guard generativeAnswerService.status.isReady else {
            completion(Feedback(
                message: generativeUnavailableMessage(for: generativeAnswerService.status),
                success: false,
                followUp: nil
            ))
            return
        }

        generativeAnswerService.respond(
            to: request,
            languageCode: languageCode,
            userName: userName,
            useWebContext: useWeb
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                let resolvedFollowUp = followUp ?? Self.resolveFollowUp(from: message)
                completion(Feedback(message: message, success: success, followUp: resolvedFollowUp))
            case .failure:
                completion(Feedback(message: self.sanitizeFallback(fallbackFact), success: success, followUp: followUp))
            }
        }
    }

    /// Decide se o Orvia deve continuar ouvindo após falar.
    private static func resolveFollowUp(from message: String) -> FollowUp? {
        if let urlFollowUp = openURLFollowUp(from: message) {
            return urlFollowUp
        }
        if looksLikeAwaitingReply(message) {
            return .awaitReply
        }
        return nil
    }

    /// Se a fala citou um link, prepara follow-up para abrir na internet após sim/não.
    private static func openURLFollowUp(from message: String) -> FollowUp? {
        guard let url = firstHTTPURL(in: message) else { return nil }
        return .openURL(url.absoluteString)
    }

    /// Detecta pergunta / pedido de confirmação para manter a escuta aberta.
    private static func looksLikeAwaitingReply(_ message: String) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if trimmed.hasSuffix("?") || trimmed.hasSuffix("？") {
            return true
        }

        let normalized = VoiceCommandParser.normalize(trimmed)
        let tail = String(normalized.suffix(100))
        let markers = [
            "quer que eu",
            "quer que",
            "posso ",
            "voce quer",
            "voce pode",
            "me diz",
            "me conta",
            "o que acha",
            "o que voce acha",
            "confirma",
            "topa",
            "bora ",
            "deseja",
            "prefere",
            "faz sentido",
            "te interessa",
            "posso abrir",
            "quer abrir",
            "me fala",
            "e ai",
            "e voce"
        ]
        return markers.contains { tail.contains($0) }
    }

    private static func firstHTTPURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = detector.matches(in: text, options: [], range: range)
        for match in matches {
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                continue
            }
            return url
        }
        return nil
    }

    private func fallbackText(for request: GenerativeAnswerService.SpokenRequest) -> String {
        switch request {
        case .chat(let text):
            return text
        case .action(let fact, _):
            return fact
        }
    }

    private func sanitizeFallback(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 220 { return trimmed }
        return String(trimmed.prefix(220))
    }

    private func speakItemMissing(_ index: Int, completion: @escaping (Feedback) -> Void) {
        speakAction("O item \(index) não existe no histórico.", success: false, completion: completion)
    }

    private func performWebSearch(_ query: String, completion: @escaping (Feedback) -> Void) {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components?.url else {
            speakAction("Não conseguiu montar a pesquisa.", success: false, completion: completion)
            return
        }
        NSWorkspace.shared.open(url)
        speakAction("Abrindo pesquisa na web por \"\(query)\".", success: true, completion: completion)
    }

    private func generativeUnavailableMessage(for status: GenerativeAnswerService.ModelStatus) -> String {
        // Únicas strings de sistema: o modelo ainda não pode falar.
        switch status {
        case .available:
            return usesPortuguese ? "O modelo ainda não está pronto." : "The model isn't ready yet."
        case .downloading:
            return usesPortuguese
                ? "O Apple Intelligence ainda está baixando o modelo."
                : "Apple Intelligence is still downloading the model."
        case .appleIntelligenceDisabled:
            return usesPortuguese
                ? "Ative o Apple Intelligence em Ajustes do Sistema para eu falar com você."
                : "Turn on Apple Intelligence in System Settings so I can talk to you."
        case .deviceNotEligible:
            return usesPortuguese
                ? "Este Mac não é compatível com Apple Intelligence."
                : "This Mac isn't compatible with Apple Intelligence."
        case .unavailable:
            return usesPortuguese
                ? "O modelo generativo está indisponível agora."
                : "The generative model is unavailable right now."
        case .unsupportedOS:
            return usesPortuguese
                ? "Respostas generativas pedem macOS 26 ou superior."
                : "Generative answers require macOS 26 or later."
        }
    }

    // MARK: - Clima / helpers

    private func fetchWeather(completion: @escaping (Feedback) -> Void) {
        let lang = settings.text(ptBR: "pt", en: "en")
        guard let url = URL(string: "https://wttr.in/?format=%t|%C&lang=\(lang)") else {
            speakAction("Não conseguiu consultar o tempo.", success: false, completion: completion)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            let fact = Self.weatherFact(from: data, error: error)
            DispatchQueue.main.async {
                guard let self else { return }
                if let fact {
                    self.speakAction(fact, success: true, completion: completion)
                } else {
                    self.speakAction(
                        "Não conseguiu consultar o tempo agora. Pode ser a conexão.",
                        success: false,
                        completion: completion
                    )
                }
            }
        }.resume()
    }

    nonisolated private static func weatherFact(from data: Data?, error: Error?) -> String? {
        guard error == nil,
              let data,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              text.count < 80 else {
            return nil
        }

        let parts = text.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }
        let temperature = parts.first ?? text
        if parts.count > 1 {
            return "Clima atual: \(temperature), \(parts[1].lowercased())."
        }
        return "Clima atual: \(temperature)."
    }

    private func currentLocale() -> Locale {
        Locale(identifier: settings.text(ptBR: "pt_BR", en: "en_US"))
    }

    private func websiteURL(from site: String) -> URL? {
        var address = site.replacingOccurrences(of: " ", with: "")
        guard !address.isEmpty else { return nil }
        if !address.contains("://") { address = "https://" + address }
        if !address.contains(".") { address += ".com" }
        guard let url = URL(string: address), url.host != nil else { return nil }
        return url
    }

    private func itemSpeechContext(_ item: DecodedClipboardItem) -> String {
        switch item.kind {
        case .text:
            guard let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return "texto vazio"
            }
            if text.count <= 400 { return text }
            return String(text.prefix(400)) + "…"
        case .image:
            return "uma imagem"
        }
    }

    private func openApplication(named name: String) -> Bool {
        if let url = resolveApplicationURL(named: name) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return true
        }
        return false
    }

    private func resolveApplicationURL(named name: String) -> URL? {
        let query = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }

        let fileManager = FileManager.default
        let directories = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            (fileManager.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent("Applications")
        ]

        var exactMatch: URL?
        var prefixMatch: URL?
        var containsMatch: URL?

        for directory in directories {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for entry in contents where entry.hasSuffix(".app") {
                let appName = (entry as NSString).deletingPathExtension.lowercased()
                let url = URL(fileURLWithPath: directory).appendingPathComponent(entry)

                if appName == query {
                    exactMatch = url
                } else if exactMatch == nil, prefixMatch == nil, appName.hasPrefix(query) {
                    prefixMatch = url
                } else if exactMatch == nil, prefixMatch == nil, containsMatch == nil, appName.contains(query) {
                    containsMatch = url
                }
            }
            if exactMatch != nil { break }
        }

        return exactMatch ?? prefixMatch ?? containsMatch
    }

    private var usesPortuguese: Bool {
        switch settings.language {
        case .portuguese: return true
        case .english: return false
        case .system:
            return Locale.preferredLanguages.first?.lowercased().hasPrefix("pt") == true
        }
    }

    private func runShellCommand(_ path: String, arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try? process.run()
    }

    private func adjustVolume(_ action: VolumeAction) {
        switch action {
        case .up: SystemKeySimulator.volumeUp()
        case .down: SystemKeySimulator.volumeDown()
        case .mute: SystemKeySimulator.mute()
        }
    }

    private func adjustBrightness(_ action: BrightnessAction) {
        switch action {
        case .up: SystemKeySimulator.brightnessUp()
        case .down: SystemKeySimulator.brightnessDown()
        }
    }
}
