import AppKit
import Foundation

/// Conecta comandos de voz às ações do app e à conversa local.
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

    func prewarmConversation() {
        generativeAnswerService.prewarm(userName: settings.userName.isEmpty ? nil : settings.userName)
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
                opened ? "Abri o app \(name)." : "Não encontrei o app chamado \(name).",
                success: opened,
                completion: completion
            )

        case .screenshotFull:
            screenshotService.capture(.fullScreen) { [weak self] success in
                guard let self else { return }
                self.speakAction(
                    success ? "Print da tela inteira salvo no histórico." : "Não consegui capturar a tela.",
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
            speakAction("Abri o painel do Orvia.", success: true, completion: completion)

        case .closePanel:
            closePanel()
            speakAction("Fechei o painel do Orvia.", success: true, completion: completion)

        case .copyItem(let index):
            panelViewModel.refresh()
            guard let item = panelViewModel.item(atDisplayIndex: index) else {
                speakItemMissing(index, completion: completion)
                return
            }
            let copied = panelViewModel.copyToPasteboard(item: item)
            speakAction(
                copied ? "Copiei o item \(index) do histórico." : "Não consegui copiar o item \(index).",
                success: copied,
                completion: completion
            )

        case .pasteItem(let index):
            panelViewModel.refresh()
            guard let item = panelViewModel.item(atDisplayIndex: index) else {
                speakItemMissing(index, completion: completion)
                return
            }
            panelViewModel.paste(item: item, targetApplication: targetApplicationProvider()) { [weak self] pasted in
                guard let self else { return }
                self.speakAction(
                    pasted ? "Colei o item \(index) do histórico." : self.automaticPasteFailureMessage,
                    success: pasted,
                    completion: completion
                )
            }

        case .pasteLast:
            panelViewModel.refresh()
            guard let item = panelViewModel.mostRecentItem() else {
                speakAction("O histórico está vazio.", success: false, completion: completion)
                return
            }
            panelViewModel.paste(item: item, targetApplication: targetApplicationProvider()) { [weak self] pasted in
                guard let self else { return }
                self.speakAction(
                    pasted ? "Colei o último item do histórico." : self.automaticPasteFailureMessage,
                    success: pasted,
                    completion: completion
                )
            }

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
                copied ? "Copiei o último item do histórico." : "Não consegui copiar o último item.",
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
            speakAction("Marquei como favorito o item \(index).", success: true, completion: completion)

        case .deleteItem(let index):
            panelViewModel.refresh()
            guard let item = panelViewModel.item(atDisplayIndex: index) else {
                speakItemMissing(index, completion: completion)
                return
            }
            panelViewModel.delete(itemID: item.id)
            speakAction("Apaguei o item \(index) do histórico.", success: true, completion: completion)

        case .pinItem(let index):
            panelViewModel.refresh()
            guard let item = panelViewModel.item(atDisplayIndex: index) else {
                speakItemMissing(index, completion: completion)
                return
            }
            let wasPinned = item.isPinned
            panelViewModel.togglePin(itemID: item.id)
            speakAction(
                wasPinned ? "Desafixei o item \(index)." : "Fixei o item \(index).",
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
            speakAction("Limpei o histórico da área de transferência.", success: true, completion: completion)

        case .dictate(let text):
            pasteService.paste(text: text, targetApplication: targetApplicationProvider()) { [weak self] pasted in
                guard let self else { return }
                self.speakAction(
                    pasted ? "Digitei o texto ditado." : self.automaticPasteFailureMessage,
                    success: pasted,
                    completion: completion
                )
            }

        case .formatJSONLast:
            panelViewModel.refresh()
            let ok = panelViewModel.formatMostRecentJSON()
            speakAction(
                ok ? "Formatei o JSON do último item e copiei." : "O último item não é um JSON válido.",
                success: ok,
                completion: completion
            )

        case .transformLast(let transform):
            panelViewModel.refresh()
            let ok = panelViewModel.transformMostRecent(transform)
            let name = transform.title(for: settings.language)
            speakAction(
                ok ? "Apliquei \(name) no último item e copiei." : "Não consegui aplicar \(name) no último item.",
                success: ok,
                completion: completion
            )

        case .saveSnippet(let name):
            panelViewModel.refresh()
            let saved = panelViewModel.saveMostRecentAsSnippet(named: name)
            speakAction(
                saved ? "Salvei o snippet \(name)." : "Não havia nada para salvar como snippet.",
                success: saved,
                completion: completion
            )

        case .pasteSnippet(let name):
            panelViewModel.refresh()
            guard let item = panelViewModel.snippet(named: name) else {
                speakAction("Não encontrei o snippet \(name).", success: false, completion: completion)
                return
            }
            panelViewModel.paste(item: item, targetApplication: targetApplicationProvider()) { [weak self] pasted in
                guard let self else { return }
                self.speakAction(
                    pasted ? "Colei o snippet \(name)." : self.automaticPasteFailureMessage,
                    success: pasted,
                    completion: completion
                )
            }

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
                "Adicionei o item \(index) à pilha. A pilha agora tem \(panelViewModel.pasteStack.count) itens.",
                success: true,
                completion: completion
            )

        case .stackPasteNext:
            let hadItem = panelViewModel.pasteNextFromStack(targetApplication: targetApplicationProvider()) { [weak self] pasted in
                guard let self else { return }
                self.speakAction(
                    pasted
                        ? "Colei o próximo da pilha. Restam \(self.panelViewModel.pasteStack.count)."
                        : "Não consegui colar automaticamente. O item continua na pilha.",
                    success: pasted,
                    completion: completion
                )
            }
            if !hadItem {
                speakAction("A pilha de colagem está vazia.", success: false, completion: completion)
            }

        case .stackClear:
            panelViewModel.clearStack()
            speakAction("Limpei a pilha de colagem.", success: true, completion: completion)

        case .pauseMonitoring:
            settings.pauseMonitoring = true
            speakAction("Pausei o monitoramento da área de transferência.", success: true, completion: completion)

        case .resumeMonitoring:
            settings.pauseMonitoring = false
            speakAction("Retomei o monitoramento da área de transferência.", success: true, completion: completion)

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
                let opened = NSWorkspace.shared.open(url)
                speakAction(
                    opened ? "Abri o site \(url.host ?? site)." : "Não consegui abrir o site \(url.host ?? site).",
                    success: opened,
                    completion: completion
                )
            } else {
                speakAction("Não consegui montar o endereço \(site).", success: false, completion: completion)
            }

        case .setUserName(let name):
            settings.userName = name
            speakAction("Guardei seu nome como \(name).", success: true, completion: completion)

        case .openDeveloperProfile:
            let opened = URL(string: Self.developerLinkedInURL).map(NSWorkspace.shared.open) ?? false
            speakAction(
                opened
                    ? "Abri o LinkedIn de \(Self.developerName)."
                    : "Não consegui abrir o LinkedIn agora.",
                success: opened,
                completion: completion
            )

        case .openSettings:
            openSettings()
            speakAction("Abri as configurações do Orvia.", success: true, completion: completion)

        case .setVoiceEnabled(let enabled):
            settings.voiceControlEnabled = enabled
            speakAction(
                enabled ? "Ativei os comandos de voz." : "Desativei os comandos de voz.",
                success: true,
                completion: completion
            )

        case .lockScreen:
            let slept = runShellCommand("/usr/bin/pmset", arguments: ["displaysleepnow"])
            speakAction(
                slept ? "Coloquei a tela em repouso." : "Não consegui colocar a tela em repouso.",
                success: slept,
                completion: completion
            )

        case .openSpotlight:
            SystemKeySimulator.openSpotlight()
            speakAction("Abri o Spotlight.", success: true, completion: completion)

        case .volumeAdjust(let action):
            adjustVolume(action)
            let fact: String
            switch action {
            case .up: fact = "Aumentei o volume."
            case .down: fact = "Diminuí o volume."
            case .mute: fact = "Silenciei o som."
            }
            speakAction(fact, success: true, completion: completion)

        case .brightnessAdjust(let action):
            adjustBrightness(action)
            let fact: String
            switch action {
            case .up: fact = "Aumentei o brilho da tela."
            case .down: fact = "Diminuí o brilho da tela."
            }
            speakAction(fact, success: true, completion: completion)

        case .openFolder(let folder):
            let opened = NSWorkspace.shared.open(folder.url)
            speakAction(
                opened
                    ? "Abri a pasta \(folder.spokenName(pt: usesPortuguese))."
                    : "Não consegui abrir a pasta \(folder.spokenName(pt: usesPortuguese)).",
                success: opened,
                completion: completion
            )

        case .searchHistory(let query):
            panelViewModel.searchText = query
            panelViewModel.setFilter(.all)
            openPanel()
            speakAction("Busquei \"\(query)\" no histórico e abri o painel.", success: true, completion: completion)

        case .showFilter(let filter):
            panelViewModel.setFilter(filter)
            openPanel()
            speakAction(
                "Mostrei o filtro \(filter.title(for: settings.language)) no painel.",
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
            speakAction("Não entendi a resposta.", success: false, completion: completion)
            return
        }

        switch followUp {
        case .awaitReply:
            execute(rawText: cleaned, completion: completion)

        case .webSearch(let query):
            if isNegativeReply(cleaned) {
                speakAction("Tudo bem, deixamos para lá.", success: true, completion: completion)
            } else if isAffirmativeReply(cleaned) {
                chatWithAI(query, completion: completion)
            } else {
                execute(rawText: cleaned, completion: completion)
            }

        case .openURL(let urlString):
            if isNegativeReply(cleaned) {
                speakAction("Tudo bem, deixamos para lá.", success: true, completion: completion)
            } else if isAffirmativeReply(cleaned) {
                if let url = URL(string: urlString) {
                    let opened = NSWorkspace.shared.open(url)
                    speakAction(
                        opened ? "Abri o link." : "Não consegui abrir o link.",
                        success: opened,
                        completion: completion
                    )
                } else {
                    speakAction("Não consegui abrir o link.", success: false, completion: completion)
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

    // MARK: - Respostas

    private func speakAction(
        _ fact: String,
        success: Bool,
        followUp: FollowUp? = nil,
        completion: @escaping (Feedback) -> Void
    ) {
        // O resultado já foi verificado pelo comando. Gerá-lo de novo atrasava a resposta
        // e podia trocar uma confirmação precisa por uma afirmação inventada.
        completion(Feedback(message: fact, success: success, followUp: followUp))
    }

    private var automaticPasteFailureMessage: String {
        settings.text(
            ptBR: "Não consegui colar automaticamente. Confira a Acessibilidade ou use Comando V.",
            en: "I couldn't paste automatically. Check Accessibility or press Command V."
        )
    }

    /// Conversa livre com busca apenas quando a pergunta depende de fatos atuais.
    private func chatWithAI(_ userText: String, completion: @escaping (Feedback) -> Void) {
        let cleaned = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            speakAction("Não entendi o que você disse.", success: false, completion: completion)
            return
        }
        guard settings.generativeAnswersEnabled else {
            completion(Feedback(
                message: settings.text(
                    ptBR: "Ative Respostas generativas em Inteligência para conversar comigo.",
                    en: "Enable Generative answers in Intelligence to chat with me."
                ),
                success: false
            ))
            return
        }

        let needsCurrentSource = QuestionPreprocessor.requiresCurrentInformation(cleaned)
        guard !needsCurrentSource || settings.generativeUseWebContext else {
            completion(Feedback(
                message: settings.text(
                    ptBR: "Para confirmar isso, preciso do Contexto da web ativado em Inteligência.",
                    en: "I need Web context enabled in Intelligence to verify that."
                ),
                success: false
            ))
            return
        }
        respond(to: cleaned, useWeb: needsCurrentSource, completion: completion)
    }

    private func respond(
        to question: String,
        useWeb: Bool,
        completion: @escaping (Feedback) -> Void
    ) {
        let languageCode = settings.text(ptBR: "pt", en: "en")
        let userName = settings.userName.isEmpty ? nil : settings.userName

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
            to: question,
            languageCode: languageCode,
            userName: userName,
            useWebContext: useWeb
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                completion(Feedback(message: message, success: true, followUp: Self.resolveFollowUp(from: message)))
            case .failure(let error):
                let message: String
                if case GenerativeAnswerError.currentSourceUnavailable = error {
                    message = self.settings.text(
                        ptBR: "Não consegui confirmar isso em uma fonte atual. Tente novamente daqui a pouco.",
                        en: "I couldn't verify that with a current source. Please try again shortly."
                    )
                } else {
                    message = self.settings.text(
                        ptBR: "Não consegui responder agora. Pode tentar de outro jeito?",
                        en: "I couldn't answer right now. Could you try asking another way?"
                    )
                }
                completion(Feedback(message: message, success: false))
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

    private func speakItemMissing(_ index: Int, completion: @escaping (Feedback) -> Void) {
        speakAction("O item \(index) não existe no histórico.", success: false, completion: completion)
    }

    private func performWebSearch(_ query: String, completion: @escaping (Feedback) -> Void) {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components?.url else {
            speakAction("Não consegui preparar a pesquisa.", success: false, completion: completion)
            return
        }
        let opened = NSWorkspace.shared.open(url)
        speakAction(
            opened ? "Abri uma pesquisa na web por \"\(query)\"." : "Não consegui abrir a pesquisa agora.",
            success: opened,
            completion: completion
        )
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
            speakAction("Não consegui consultar o tempo.", success: false, completion: completion)
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
                        "Não consegui consultar o tempo agora. Pode ser a conexão.",
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

    private func runShellCommand(_ path: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
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
