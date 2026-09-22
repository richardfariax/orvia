import XCTest
@testable import Orvia

final class VoiceCommandParserTests: XCTestCase {
    func testOpenApp() {
        XCTAssertEqual(VoiceCommandParser.parse("abra o Xcode"), .openApp("Xcode"))
        XCTAssertEqual(VoiceCommandParser.parse("abrir Safari"), .openApp("Safari"))
        XCTAssertEqual(VoiceCommandParser.parse("open the Terminal"), .openApp("Terminal"))
    }

    func testScreenshot() {
        XCTAssertEqual(VoiceCommandParser.parse("tire um print"), .screenshotFull)
        XCTAssertEqual(VoiceCommandParser.parse("tire um print da área"), .screenshotArea)
        XCTAssertEqual(VoiceCommandParser.parse("take a screenshot"), .screenshotFull)
    }

    func testAnalyzeScreen() {
        XCTAssertEqual(VoiceCommandParser.parse("veja o que está na tela"), .analyzeScreen)
        XCTAssertEqual(VoiceCommandParser.parse("analise o que tem na tela"), .analyzeScreen)
        XCTAssertEqual(VoiceCommandParser.parse("o que tem na tela"), .analyzeScreen)
        XCTAssertEqual(VoiceCommandParser.parse("leia a tela"), .analyzeScreen)
        XCTAssertEqual(VoiceCommandParser.parse("what's on the screen"), .analyzeScreen)
    }

    func testPanel() {
        XCTAssertEqual(VoiceCommandParser.parse("abra o painel"), .openPanel)
        XCTAssertEqual(VoiceCommandParser.parse("feche o painel"), .closePanel)
    }

    func testClipboardItems() {
        XCTAssertEqual(VoiceCommandParser.parse("copie o item 2"), .copyItem(2))
        XCTAssertEqual(VoiceCommandParser.parse("cole o item três"), .pasteItem(3))
        XCTAssertEqual(VoiceCommandParser.parse("cole o último"), .pasteLast)
        XCTAssertEqual(VoiceCommandParser.parse("favorite o item 1"), .favoriteItem(1))
        XCTAssertEqual(VoiceCommandParser.parse("limpar histórico"), .clearHistory)
    }

    func testDictate() {
        XCTAssertEqual(VoiceCommandParser.parse("digite bom dia equipe"), .dictate("bom dia equipe"))
    }

    func testSnippets() {
        XCTAssertEqual(VoiceCommandParser.parse("salve como deploy"), .saveSnippet("deploy"))
        XCTAssertEqual(VoiceCommandParser.parse("cole o snippet deploy"), .pasteSnippet("deploy"))
    }

    func testStack() {
        XCTAssertEqual(VoiceCommandParser.parse("adicione o item 2 à pilha"), .stackAdd(2))
        XCTAssertEqual(VoiceCommandParser.parse("cole a pilha"), .stackPasteNext)
        XCTAssertEqual(VoiceCommandParser.parse("limpar pilha"), .stackClear)
    }

    func testMonitoringAndJSON() {
        XCTAssertEqual(VoiceCommandParser.parse("pausar monitoramento"), .pauseMonitoring)
        XCTAssertEqual(VoiceCommandParser.parse("retomar monitoramento"), .resumeMonitoring)
        XCTAssertEqual(VoiceCommandParser.parse("formate o json"), .formatJSONLast)
    }

    func testUtilityActions() {
        XCTAssertEqual(VoiceCommandParser.parse("que horas são"), .currentTime)
        XCTAssertEqual(VoiceCommandParser.parse("que dia é hoje"), .currentDate)
        XCTAssertEqual(VoiceCommandParser.parse("quantos graus agora"), .weather)
        XCTAssertEqual(VoiceCommandParser.parse("como está o tempo"), .weather)
        XCTAssertEqual(VoiceCommandParser.parse("abra o site github.com"), .openWebsite("github.com"))
        XCTAssertEqual(VoiceCommandParser.parse("abra github ponto com"), .openWebsite("github.com"))
        XCTAssertEqual(VoiceCommandParser.parse("pesquise swift concurrency"), .webSearch("swift concurrency"))
    }

    func testSetUserName() {
        XCTAssertEqual(VoiceCommandParser.parse("meu nome é Richard"), .setUserName("Richard"))
    }

    func testConversationGoesToAI() {
        // Conversa / perguntas não são comandos fixos — o executor manda para a IA.
        XCTAssertNil(VoiceCommandParser.parse("quem é o presidente do Brasil"))
        XCTAssertNil(VoiceCommandParser.parse("o que é fotossíntese"))
        XCTAssertNil(VoiceCommandParser.parse("bom dia"))
        XCTAssertNil(VoiceCommandParser.parse("oi"))
        XCTAssertNil(VoiceCommandParser.parse("obrigado"))
        XCTAssertNil(VoiceCommandParser.parse("quem é você"))
        XCTAssertNil(VoiceCommandParser.parse("quem te criou"))
        XCTAssertNil(VoiceCommandParser.parse("o que você sabe fazer"))
        XCTAssertNil(VoiceCommandParser.parse("qual é o meu nome"))
    }

    func testQuestionPreprocessor() {
        XCTAssertEqual(QuestionPreprocessor.prepare("orvia quem é o presidente do brasil"), "quem é o presidente do brasil")
        XCTAssertEqual(QuestionPreprocessor.prepare("eu quero saber qual a capital do brasil"), "qual a capital do brasil")
        XCTAssertNil(QuestionPreprocessor.prepare("bom dia"))
    }

    func testCurrentInformationRouting() {
        XCTAssertTrue(QuestionPreprocessor.requiresCurrentInformation("Quem é o presidente do Brasil?"))
        XCTAssertTrue(QuestionPreprocessor.requiresCurrentInformation("Qual a cotação do dólar hoje?"))
        XCTAssertTrue(QuestionPreprocessor.requiresCurrentInformation("What is the latest release?"))
        XCTAssertFalse(QuestionPreprocessor.requiresCurrentInformation("Como organizar minhas tarefas hoje?"))
        XCTAssertFalse(QuestionPreprocessor.requiresCurrentInformation("Me ajude a escrever um e-mail curto"))
        XCTAssertFalse(QuestionPreprocessor.requiresCurrentInformation("O que é um snippet?"))
    }

    @MainActor
    func testPreferredVoicePersists() throws {
        let suiteName = "VoiceCommandParserTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(userDefaults: defaults)
        XCTAssertEqual(settings.voiceIdentifier, "")
        settings.voiceIdentifier = "com.apple.voice.compact.pt-BR.Luciana"

        let restored = AppSettings(userDefaults: defaults)
        XCTAssertEqual(restored.voiceIdentifier, settings.voiceIdentifier)
    }

    func testOpenDeveloperProfileAction() {
        XCTAssertEqual(VoiceCommandParser.parse("abra o linkedin do dono"), .openDeveloperProfile)
        XCTAssertEqual(VoiceCommandParser.parse("abra o linkedin"), .openWebsite("linkedin.com"))
        XCTAssertTrue(AssistantIntentDetector.isDeveloperProfileRequest("abra o linkedin do dono"))
    }

    func testUnknownReturnsNil() {
        XCTAssertNil(VoiceCommandParser.parse(""))
    }

    func testMath() {
        XCTAssertEqual(VoiceCommandParser.parse("quanto é 15 mais 7"), .calculate("22"))
        XCTAssertEqual(VoiceCommandParser.parse("calcule 10 vezes 3"), .calculate("30"))
    }

    func testExtendedClipboardCommands() {
        XCTAssertEqual(VoiceCommandParser.parse("o que eu copiei"), .readLastItem)
        XCTAssertEqual(VoiceCommandParser.parse("copie o último"), .copyLastItem)
        XCTAssertEqual(VoiceCommandParser.parse("quantos itens no histórico"), .historyCount)
        XCTAssertEqual(VoiceCommandParser.parse("apague o item 2"), .deleteItem(2))
        XCTAssertEqual(VoiceCommandParser.parse("fixe o item 1"), .pinItem(1))
        XCTAssertEqual(VoiceCommandParser.parse("busque no histórico deploy"), .searchHistory("deploy"))
    }

    func testTextTransforms() {
        XCTAssertEqual(VoiceCommandParser.parse("minifique o json"), .transformLast(.minifyJSON))
        XCTAssertEqual(VoiceCommandParser.parse("em maiúsculas"), .transformLast(.upperCase))
        XCTAssertEqual(VoiceCommandParser.parse("codificar base64"), .transformLast(.base64Encode))
    }

    func testSystemCommands() {
        XCTAssertEqual(VoiceCommandParser.parse("abra as configurações"), .openSettings)
        XCTAssertEqual(VoiceCommandParser.parse("bloqueie a tela"), .lockScreen)
        XCTAssertEqual(VoiceCommandParser.parse("abra o spotlight"), .openSpotlight)
        XCTAssertEqual(VoiceCommandParser.parse("aumente o volume"), .volumeAdjust(.up))
        XCTAssertEqual(VoiceCommandParser.parse("suba o volume"), .volumeAdjust(.up))
        XCTAssertEqual(VoiceCommandParser.parse("aumente o brilho da tela"), .brightnessAdjust(.up))
        XCTAssertEqual(VoiceCommandParser.parse("diminua o brilho"), .brightnessAdjust(.down))
        XCTAssertEqual(VoiceCommandParser.parse("deixe a tela mais clara"), .brightnessAdjust(.up))
        XCTAssertEqual(VoiceCommandParser.parse("abra downloads"), .openFolder(.downloads))
        XCTAssertEqual(VoiceCommandParser.parse("mostre favoritos"), .showFilter(.favorites))
        XCTAssertEqual(VoiceCommandParser.parse("liste os snippets"), .listSnippets)
        XCTAssertEqual(VoiceCommandParser.parse("que dia da semana é hoje"), .dayOfWeek)
    }

    func testWebsiteAliases() {
        XCTAssertEqual(VoiceCommandParser.parse("abra o youtube"), .openWebsite("youtube.com"))
        XCTAssertEqual(VoiceCommandParser.parse("abra o gmail"), .openWebsite("gmail.com"))
    }

    func testVoiceControlToggle() {
        XCTAssertEqual(VoiceCommandParser.parse("ative comandos de voz"), .setVoiceEnabled(true))
        XCTAssertEqual(VoiceCommandParser.parse("desative comandos de voz"), .setVoiceEnabled(false))
    }

    func testSearchQueryFromUnknownSpeech() {
        XCTAssertEqual(
            KnowledgeService.searchQuery(from: "quem inventou o avião"),
            "quem inventou o avião"
        )
        XCTAssertNil(KnowledgeService.searchQuery(from: "bom dia"))
    }

    func testResolveSearchQueryFallback() {
        XCTAssertEqual(
            KnowledgeService.resolveSearchQuery(from: "orvia fotossíntese"),
            "fotossíntese"
        )
        XCTAssertEqual(
            KnowledgeService.resolveSearchQuery(from: "inteligência artificial"),
            "inteligência artificial"
        )
        XCTAssertEqual(
            KnowledgeService.resolveSearchQuery(from: "quem inventou o avião"),
            "quem inventou o avião"
        )
        XCTAssertNil(KnowledgeService.resolveSearchQuery(from: "obrigado"))
        XCTAssertNil(KnowledgeService.resolveSearchQuery(from: ""))
    }
}
