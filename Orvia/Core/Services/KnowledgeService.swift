import Foundation

/// Responde perguntas factuais usando fontes gratuitas e sem chave de API:
/// 1. Wikidata (titulares de cargos, pessoas, dados estruturados)
/// 2. Wikipedia (busca ranqueada + resumo do artigo)
/// 3. DuckDuckGo Instant Answers (fallback)
final class KnowledgeService {
    private let timeout: TimeInterval = 8
    private let webSnippetSearch = WebSnippetSearchService()

    enum QuestionIntent: Equatable {
        case who
        case what
        case when
        case whereLocation
        case howMany
        case general
    }

    struct QuestionAnalysis {
        let intent: QuestionIntent
        let searchQueries: [String]
        let coreTerms: String
    }

    private struct AnswerCandidate {
        let text: String
        let score: Int
    }

    /// - Parameters:
    ///   - question: pergunta em linguagem natural ("quem é o presidente do brasil").
    ///   - languageCode: "pt" ou "en".
    func answer(question: String, languageCode: String, completion: @escaping (String?) -> Void) {
        let cleaned = Self.cleanQuestion(question)
        let analysis = Self.analyze(question: cleaned)
        guard !analysis.searchQueries.isEmpty else {
            completion(nil)
            return
        }

        var candidates: [AnswerCandidate] = []
        let group = DispatchGroup()

        group.enter()
        fetchWikidataAnswer(analysis: analysis, languageCode: languageCode) { answer in
            if let answer {
                candidates.append(AnswerCandidate(
                    text: answer,
                    score: Self.scoreAnswer(answer, analysis: analysis) + 20
                ))
            }
            group.leave()
        }

        group.enter()
        fetchWikipediaAnswer(analysis: analysis, question: cleaned, languageCode: languageCode) { answer in
            if let answer {
                candidates.append(AnswerCandidate(
                    text: answer,
                    score: Self.scoreAnswer(answer, analysis: analysis) + 10
                ))
            }
            group.leave()
        }

        group.enter()
        fetchDuckDuckGoAnswer(query: analysis.searchQueries[0]) { answer in
            if let answer {
                candidates.append(AnswerCandidate(
                    text: answer,
                    score: Self.scoreAnswer(answer, analysis: analysis)
                ))
            }
            group.leave()
        }

        group.notify(queue: .main) {
            let relevant = candidates.filter {
                Self.isAnswerRelevant($0.text, to: cleaned) && $0.score >= 18
            }

            if let best = relevant.max(by: { $0.score < $1.score }) {
                completion(Self.trimForSpeech(best.text))
            } else {
                completion(nil)
            }
        }
    }

    /// Verifica se a resposta tem relação suficiente com a pergunta.
    static func isAnswerRelevant(_ answer: String, to question: String) -> Bool {
        let cleaned = cleanQuestion(question)
        guard !cleaned.isEmpty else { return false }
        let analysis = analyze(question: cleaned)
        return scoreAnswer(answer, analysis: analysis) >= 18
    }

    // MARK: - Análise da pergunta

    static func cleanQuestion(_ question: String) -> String {
        var normalized = normalize(question)
        normalized = stripLeadingFillers(normalized)
        normalized = applyTermAliases(normalized)
        return normalized
    }

    static func analyze(question: String) -> QuestionAnalysis {
        let cleaned = cleanQuestion(question)
        let intent = detectIntent(cleaned)
        let baseTerms = searchTerms(from: cleaned)
        var queries: [String] = []

        if !baseTerms.isEmpty {
            queries.append(baseTerms)
        }

        switch intent {
        case .who:
            if !baseTerms.isEmpty {
                if roleTerms(in: baseTerms) {
                    queries.insert(baseTerms + " titular atual", at: 0)
                    queries.insert(baseTerms + " atual", at: 0)
                }
                if baseTerms.hasPrefix("quem foi ") || cleaned.contains("quem foi") {
                    queries.append(String(baseTerms.dropFirst("quem foi ".count)))
                }
            }
        case .what:
            if !baseTerms.isEmpty {
                queries.append(baseTerms + " definicao")
            }
        case .whereLocation:
            if baseTerms.contains("capital") {
                queries.insert(baseTerms, at: 0)
            } else if !baseTerms.isEmpty {
                queries.insert("capital " + baseTerms, at: 0)
            }
        case .when, .howMany, .general:
            break
        }

        if let mapped = knownQueryMapping(for: baseTerms) {
            queries.insert(mapped, at: 0)
        }

        return QuestionAnalysis(
            intent: intent,
            searchQueries: uniqueNonEmpty(queries),
            coreTerms: baseTerms
        )
    }

    static func detectIntent(_ normalized: String) -> QuestionIntent {
        let text = stripLeadingFillers(normalized)

        if text.hasPrefix("quem ") || text.hasPrefix("who ")
            || text.contains("quem e ") || text.contains("quem foi ")
            || text.contains("who is ") || text.contains("who was ") {
            return .who
        }

        if text.hasPrefix("onde ") || text.hasPrefix("where ")
            || text.contains("onde fica ") || text.contains("onde e ")
            || text.contains("capital de ") || text.contains("capital do ") || text.contains("capital da ")
            || text.contains("where is ") {
            return .whereLocation
        }

        if text.hasPrefix("qual ") || text.hasPrefix("quais ")
            || text.contains("qual e ") || text.contains("qual o ") || text.contains("qual a ")
            || text.contains("what is ") || text.contains("which ") {
            return roleTerms(in: searchTerms(from: text)) ? .who : .what
        }

        if text.hasPrefix("o que ") || text.hasPrefix("what ")
            || text.contains("o que e ") || text.contains("o que significa ")
            || text.contains("what are ") {
            return .what
        }

        if text.hasPrefix("quando ") || text.hasPrefix("when ")
            || text.contains("quando foi ") || text.contains("quando e ")
            || text.contains("when was ") || text.contains("when is ") {
            return .when
        }

        if text.hasPrefix("quantos ") || text.hasPrefix("quantas ")
            || text.hasPrefix("quanto ") || text.contains("how many ")
            || text.contains("quantos habitantes") || text.contains("populacao") {
            return .howMany
        }

        if text.contains("como funciona") || text.contains("como e ")
            || text.contains("how does") || text.contains("how do") {
            return .what
        }

        if roleTerms(in: searchTerms(from: text)) {
            return .who
        }

        if text.contains("capital de") || text.contains("capital do") {
            return .whereLocation
        }

        return .general
    }

    /// Remove prefixos interrogativos para extrair os termos de busca.
    static func searchTerms(from question: String) -> String {
        var normalized = cleanQuestion(question)

        let prefixes = [
            "quem e o", "quem e a", "quem sao os", "quem sao as", "quem foi o", "quem foi a", "quem foi", "quem e",
            "qual e o", "qual e a", "qual o", "qual a", "quais sao os", "quais sao as", "quais sao", "qual e",
            "o que e um", "o que e uma", "o que e", "o que sao", "o que significa",
            "quando foi", "quando e", "onde fica o", "onde fica a", "onde fica", "onde e",
            "quantos", "quantas", "quanto custa", "quanto e", "como funciona", "como e",
            "me fale sobre", "me fala sobre", "me explica", "me explicar", "fale sobre",
            "who is the", "who is", "who was", "who are",
            "what is the", "what is a", "what is", "what are", "what was",
            "when was", "when is", "where is the", "where is", "how many", "tell me about",
            "quem", "qual", "quais", "o que", "quando", "onde", "como", "who", "what", "when", "where"
        ]

        for prefix in prefixes.sorted(by: { $0.count > $1.count }) where normalized.hasPrefix(prefix + " ") {
            normalized = String(normalized.dropFirst(prefix.count + 1))
            break
        }

        let fillers = ["agora", "atual", "hoje", "mesmo", "right now", "today", "currently"]
        var words = normalized.split(separator: " ").map(String.init)
        words.removeAll { fillers.contains($0) }

        return applyTermAliases(words.joined(separator: " "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func knownQueryMapping(for terms: String) -> String? {
        let mappings: [String: String] = [
            "presidente do brasil": "presidente do brasil",
            "presidente brasil": "presidente do brasil",
            "presidente da republica": "presidente do brasil",
            "capital do brasil": "capital do brasil",
            "capital brasil": "capital do brasil",
            "presidente dos estados unidos": "presidente dos estados unidos",
            "presidente eua": "presidente dos estados unidos",
            "presidente estados unidos": "presidente dos estados unidos"
        ]
        return mappings[terms]
    }

    private static func roleTerms(in terms: String) -> Bool {
        let roles = [
            "presidente", "primeiro ministro", "primeira ministra", "ministro", "ministra",
            "governador", "governadora", "prefeito", "prefeita", "papa", "rei", "rainha",
            "ceo", "diretor", "diretora", "president", "prime minister", "minister",
            "governor", "mayor", "pope", "king", "queen", "secretario", "secretaria"
        ]
        return roles.contains { terms.contains($0) }
    }

    // MARK: - Wikidata

    private func fetchWikidataAnswer(analysis: QuestionAnalysis, languageCode: String, completion: @escaping (String?) -> Void) {
        guard analysis.intent == .who || analysis.intent == .what else {
            completion(nil)
            return
        }

        tryWikidataQueries(analysis.searchQueries, index: 0, intent: analysis.intent, languageCode: languageCode, completion: completion)
    }

    private func tryWikidataQueries(
        _ queries: [String],
        index: Int,
        intent: QuestionIntent,
        languageCode: String,
        completion: @escaping (String?) -> Void
    ) {
        guard index < queries.count else {
            completion(nil)
            return
        }

        searchWikidataEntities(query: queries[index], languageCode: languageCode) { [weak self] entityIDs in
            guard let self else {
                completion(nil)
                return
            }
            guard !entityIDs.isEmpty else {
                self.tryWikidataQueries(queries, index: index + 1, intent: intent, languageCode: languageCode, completion: completion)
                return
            }

            self.tryWikidataEntities(
                entityIDs,
                index: 0,
                intent: intent,
                languageCode: languageCode
            ) { answer in
                if let answer {
                    completion(answer)
                } else {
                    self.tryWikidataQueries(queries, index: index + 1, intent: intent, languageCode: languageCode, completion: completion)
                }
            }
        }
    }

    private func tryWikidataEntities(
        _ entityIDs: [String],
        index: Int,
        intent: QuestionIntent,
        languageCode: String,
        completion: @escaping (String?) -> Void
    ) {
        guard index < entityIDs.count else {
            completion(nil)
            return
        }

        fetchWikidataEntityAnswer(entityID: entityIDs[index], intent: intent, languageCode: languageCode) { [weak self] answer in
            if let answer {
                completion(answer)
            } else {
                self?.tryWikidataEntities(entityIDs, index: index + 1, intent: intent, languageCode: languageCode, completion: completion)
            }
        }
    }

    private func searchWikidataEntities(query: String, languageCode: String, completion: @escaping ([String]) -> Void) {
        guard var components = URLComponents(string: "https://www.wikidata.org/w/api.php") else {
            completion([])
            return
        }
        components.queryItems = [
            URLQueryItem(name: "action", value: "wbsearchentities"),
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "language", value: languageCode),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components.url else {
            completion([])
            return
        }

        fetch(url) { data in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let search = json["search"] as? [[String: Any]] else {
                completion([])
                return
            }

            let ids = search.compactMap { $0["id"] as? String }.filter { $0.hasPrefix("Q") }
            completion(ids)
        }
    }

    private func fetchWikidataEntityAnswer(entityID: String, intent: QuestionIntent, languageCode: String, completion: @escaping (String?) -> Void) {
        guard var components = URLComponents(string: "https://www.wikidata.org/w/api.php") else {
            completion(nil)
            return
        }
        components.queryItems = [
            URLQueryItem(name: "action", value: "wbgetentities"),
            URLQueryItem(name: "ids", value: entityID),
            URLQueryItem(name: "props", value: "claims|labels|descriptions"),
            URLQueryItem(name: "languages", value: languageCode),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components.url else {
            completion(nil)
            return
        }

        fetch(url) { data in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entities = json["entities"] as? [String: Any],
                  let entity = entities[entityID] as? [String: Any] else {
                completion(nil)
                return
            }

            let officeLabel = Self.wikidataLabel(in: entity, languageCode: languageCode)

            if intent == .who {
                let holderIDs = Self.wikidataHolderEntityIDs(from: entity, property: "P1308")
                    + Self.wikidataHolderEntityIDs(from: entity, property: "P35")
                    + Self.wikidataHolderEntityIDs(from: entity, property: "P6")

                if !holderIDs.isEmpty {
                    self.fetchWikidataLabels(entityIDs: holderIDs, languageCode: languageCode) { labels in
                        guard let holderLabel = labels.first(where: { !$0.isEmpty }) else {
                            completion(nil)
                            return
                        }
                        if let officeLabel, !officeLabel.isEmpty {
                            completion(Self.formatWhoAnswer(office: officeLabel, holder: holderLabel, languageCode: languageCode))
                        } else {
                            completion(holderLabel)
                        }
                    }
                    return
                }

                if let description = Self.wikidataDescription(in: entity, languageCode: languageCode),
                   let label = officeLabel ?? description.components(separatedBy: ",").first {
                    completion(Self.formatPersonAnswer(name: label, description: description, languageCode: languageCode))
                    return
                }
            }

            if intent == .what, let description = Self.wikidataDescription(in: entity, languageCode: languageCode) {
                if let label = Self.wikidataLabel(in: entity, languageCode: languageCode) {
                    completion("\(label) é \(description).")
                } else {
                    completion(description + ".")
                }
                return
            }

            completion(nil)
        }
    }

    private func fetchWikidataLabels(entityIDs: [String], languageCode: String, completion: @escaping ([String]) -> Void) {
        guard var components = URLComponents(string: "https://www.wikidata.org/w/api.php") else {
            completion([])
            return
        }
        components.queryItems = [
            URLQueryItem(name: "action", value: "wbgetentities"),
            URLQueryItem(name: "ids", value: entityIDs.joined(separator: "|")),
            URLQueryItem(name: "props", value: "labels"),
            URLQueryItem(name: "languages", value: languageCode),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components.url else {
            completion([])
            return
        }

        fetch(url) { data in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entities = json["entities"] as? [String: Any] else {
                completion([])
                return
            }

            let labels = entityIDs.compactMap { id -> String? in
                guard let entity = entities[id] as? [String: Any] else { return nil }
                return Self.wikidataLabel(in: entity, languageCode: languageCode)
            }
            completion(labels)
        }
    }

    private static func wikidataLabel(in entity: [String: Any], languageCode: String) -> String? {
        guard let labels = entity["labels"] as? [String: Any] else { return nil }
        if let localized = labels[languageCode] as? [String: Any], let value = localized["value"] as? String {
            return value
        }
        if let english = labels["en"] as? [String: Any], let value = english["value"] as? String {
            return value
        }
        return nil
    }

    private static func wikidataDescription(in entity: [String: Any], languageCode: String) -> String? {
        guard let descriptions = entity["descriptions"] as? [String: Any] else { return nil }
        if let localized = descriptions[languageCode] as? [String: Any], let value = localized["value"] as? String {
            return value
        }
        if let english = descriptions["en"] as? [String: Any], let value = english["value"] as? String {
            return value
        }
        return nil
    }

    private static func wikidataHolderEntityIDs(from entity: [String: Any], property: String) -> [String] {
        guard let claims = entity["claims"] as? [String: Any],
              let propertyClaims = claims[property] as? [[String: Any]] else {
            return []
        }

        let ranked = propertyClaims.sorted { lhs, rhs in
            rankClaim(lhs) > rankClaim(rhs)
        }

        var holderIDs: [String] = []
        for claim in ranked {
            guard let mainsnak = claim["mainsnak"] as? [String: Any],
                  let datavalue = mainsnak["datavalue"] as? [String: Any],
                  let value = datavalue["value"] as? [String: Any],
                  let holderID = value["id"] as? String else {
                continue
            }

            if let qualifiers = claim["qualifiers"] as? [String: Any],
               let endTime = qualifiers["P582"] as? [[String: Any]],
               !endTime.isEmpty {
                continue
            }

            holderIDs.append(holderID)
        }
        return holderIDs
    }

    private static func rankClaim(_ claim: [String: Any]) -> Int {
        guard let rank = claim["rank"] as? String else { return 0 }
        switch rank {
        case "preferred": return 3
        case "normal": return 2
        case "deprecated": return 0
        default: return 1
        }
    }

    private static func formatWhoAnswer(office: String, holder: String, languageCode: String) -> String {
        if languageCode == "pt" {
            return "O \(office.lowercased()) é \(holder)."
        }
        return "The \(office.lowercased()) is \(holder)."
    }

    private static func formatPersonAnswer(name: String, description: String, languageCode: String) -> String {
        if languageCode == "pt" {
            return "\(name) é \(description)."
        }
        return "\(name) is \(description)."
    }

    // MARK: - Wikipedia

    private func fetchWikipediaAnswer(
        analysis: QuestionAnalysis,
        question: String,
        languageCode: String,
        completion: @escaping (String?) -> Void
    ) {
        var allTitles: [String] = []
        let group = DispatchGroup()

        for query in analysis.searchQueries.prefix(4) {
            group.enter()
            searchWikipediaTitles(query: query, languageCode: languageCode, limit: 4) { titles in
                allTitles.append(contentsOf: titles)
                group.leave()
            }

            group.enter()
            searchWikipediaOpenSearch(query: query, languageCode: languageCode, limit: 3) { titles in
                allTitles.append(contentsOf: titles)
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else {
                completion(nil)
                return
            }

            let rankedTitles = Self.rankTitles(
                Self.uniqueNonEmpty(allTitles),
                query: analysis.coreTerms,
                intent: analysis.intent
            )

            self.tryWikipediaTitles(
                rankedTitles,
                index: 0,
                question: question,
                intent: analysis.intent,
                languageCode: languageCode,
                completion: completion
            )
        }
    }

    private func searchWikipediaOpenSearch(query: String, languageCode: String, limit: Int, completion: @escaping ([String]) -> Void) {
        guard var components = URLComponents(string: "https://\(languageCode).wikipedia.org/w/api.php") else {
            completion([])
            return
        }
        components.queryItems = [
            URLQueryItem(name: "action", value: "opensearch"),
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components.url else {
            completion([])
            return
        }

        fetch(url) { data in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  json.count > 1,
                  let titles = json[1] as? [String] else {
                completion([])
                return
            }
            completion(titles.filter { !$0.isEmpty })
        }
    }

    private func searchWikipediaTitles(query: String, languageCode: String, limit: Int, completion: @escaping ([String]) -> Void) {
        guard var components = URLComponents(string: "https://\(languageCode).wikipedia.org/w/api.php") else {
            completion([])
            return
        }
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: query),
            URLQueryItem(name: "srlimit", value: "\(limit)"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components.url else {
            completion([])
            return
        }

        fetch(url) { data in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let query = json["query"] as? [String: Any],
                  let search = query["search"] as? [[String: Any]] else {
                completion([])
                return
            }
            let titles = search.compactMap { $0["title"] as? String }.filter { !$0.isEmpty }
            completion(titles)
        }
    }

    private static func rankTitles(_ titles: [String], query: String, intent: QuestionIntent) -> [String] {
        let queryWords = Set(searchTerms(from: query).split(separator: " ").map(String.init))

        return titles
            .filter { isUsefulTitle($0, intent: intent) }
            .sorted { lhs, rhs in
                scoreTitle(lhs, queryWords: queryWords) > scoreTitle(rhs, queryWords: queryWords)
            }
    }

    private static func isUsefulTitle(_ title: String, intent: QuestionIntent) -> Bool {
        let lower = normalize(title)
        let blocked = ["lista de", "categoria:", "anexo:", "discussao:", "ficheiro:", "portal:", "wikipedia:"]
        if blocked.contains(where: { lower.hasPrefix($0) || lower.contains($0) }) {
            return false
        }
        if intent == .who && lower.hasPrefix("lista de") {
            return false
        }
        return true
    }

    private static func scoreTitle(_ title: String, queryWords: Set<String>) -> Int {
        let titleNorm = normalize(title)
        var score = 0
        for word in queryWords where word.count > 2 {
            if titleNorm.contains(word) { score += 12 }
        }
        if titleNorm.split(separator: " ").count <= 5 { score += 5 }
        return score
    }

    private func tryWikipediaTitles(
        _ titles: [String],
        index: Int,
        question: String,
        intent: QuestionIntent,
        languageCode: String,
        completion: @escaping (String?) -> Void
    ) {
        guard index < min(titles.count, 6) else {
            completion(nil)
            return
        }

        fetchWikipediaSummary(title: titles[index], question: question, intent: intent, languageCode: languageCode) { [weak self] answer in
            if let answer, Self.scoreAnswer(answer, terms: Self.searchTerms(from: question), intent: intent) >= 10 {
                completion(answer)
            } else {
                self?.tryWikipediaTitles(titles, index: index + 1, question: question, intent: intent, languageCode: languageCode, completion: completion)
            }
        }
    }

    private func fetchWikipediaSummary(
        title: String,
        question: String,
        intent: QuestionIntent,
        languageCode: String,
        completion: @escaping (String?) -> Void
    ) {
        guard var components = URLComponents(string: "https://\(languageCode).wikipedia.org/w/api.php") else {
            completion(nil)
            return
        }
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "prop", value: "extracts"),
            URLQueryItem(name: "exintro", value: "1"),
            URLQueryItem(name: "explaintext", value: "1"),
            URLQueryItem(name: "redirects", value: "1"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "titles", value: title)
        ]
        guard let url = components.url else {
            completion(nil)
            return
        }

        fetch(url) { data in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let query = json["query"] as? [String: Any],
                  let pages = query["pages"] as? [String: Any],
                  let page = pages.values.first as? [String: Any],
                  let extract = page["extract"] as? String, !extract.isEmpty else {
                completion(nil)
                return
            }

            let answer = Self.formatAnswer(from: extract, question: question, intent: intent, languageCode: languageCode)
            completion(answer.isEmpty ? nil : answer)
        }
    }

    static func formatAnswer(from text: String, question: String, intent: QuestionIntent, languageCode: String) -> String {
        let sentences = splitSentences(text)
        guard !sentences.isEmpty else {
            return firstSentences(of: text, limit: 2)
        }

        switch intent {
        case .who:
            if let direct = extractWhoAnswer(from: sentences, languageCode: languageCode) {
                return direct
            }
            return relevantSentences(of: text)
        case .what:
            return firstSentences(of: text, limit: 1)
        case .whereLocation:
            if let location = sentences.first(where: { sentence in
                let l = sentence.lowercased()
                return l.contains("capital") || l.contains("localizada") || l.contains("localizado")
                    || l.contains("fica") || l.contains("situad") || l.contains("located")
            }) {
                return location
            }
            return firstSentences(of: text, limit: 2)
        case .when, .howMany:
            if let matched = sentences.first(where: { matchesIntent($0, intent: intent) }) {
                return matched
            }
            return firstSentences(of: text, limit: 2)
        case .general:
            return relevantSentences(of: text)
        }
    }

    private static func extractWhoAnswer(from sentences: [String], languageCode: String) -> String? {
        let currentMarkers = [
            "atual", "atualmente", "titular", "desde ", "é ", "e ",
            "currently", "incumbent", "since ", "is ", "foi "
        ]

        for sentence in sentences {
            let lowered = sentence.lowercased()
            guard currentMarkers.contains(where: { lowered.contains($0) }) else { continue }
            if sentence.count <= 220 {
                return sentence
            }
            return firstSentences(of: sentence, limit: 1)
        }

        if let first = sentences.first, first.count <= 180 {
            return first
        }
        return nil
    }

    private static func matchesIntent(_ sentence: String, intent: QuestionIntent) -> Bool {
        let lowered = sentence.lowercased()
        switch intent {
        case .when:
            return lowered.contains("em ") || lowered.contains("since ") || lowered.contains("ano") || lowered.contains("year")
        case .whereLocation:
            return lowered.contains("fica") || lowered.contains("localizado") || lowered.contains("located") || lowered.contains("situad")
        case .howMany:
            return lowered.range(of: #"\d"#, options: .regularExpression) != nil
        default:
            return false
        }
    }

    static func relevantSentences(of text: String) -> String {
        let sentences = splitSentences(text)
        guard !sentences.isEmpty else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var selected = Array(sentences.prefix(2))

        let currentMarkers = ["atual", "atualmente", "desde ", "currently", "incumbent", "since ", "titular"]
        if let currentSentence = sentences.dropFirst(2).first(where: { sentence in
            let lowered = sentence.lowercased()
            return currentMarkers.contains { lowered.contains($0) }
        }) {
            selected.append(currentSentence)
        }

        let joined = selected.joined(separator: " ")
        if joined.count > 320 {
            return firstSentences(of: joined, limit: 2)
        }
        return joined
    }

    /// Busca na internet quando o comando ou pergunta não foi reconhecido.
    /// Reutiliza Wikipedia/Wikidata/DuckDuckGo e, se necessário, fontes mais amplas.
    func searchInternet(
        query: String,
        languageCode: String,
        includePrimarySources: Bool = true,
        completion: @escaping (String?) -> Void
    ) {
        let cleaned = Self.cleanQuestion(query)
        guard !cleaned.isEmpty else {
            completion(nil)
            return
        }

        guard includePrimarySources else {
            fetchExtendedWebAnswer(query: cleaned, languageCode: languageCode, completion: completion)
            return
        }

        answer(question: cleaned, languageCode: languageCode) { [weak self] answer in
            if let answer {
                completion(answer)
                return
            }
            self?.fetchExtendedWebAnswer(query: cleaned, languageCode: languageCode, completion: completion)
        }
    }

    /// Busca agressiva para fala: tenta várias fontes gratuitas e variações da query.
    func searchInternetForSpeech(
        query: String,
        languageCode: String,
        completion: @escaping (String?) -> Void
    ) {
        let cleaned = Self.cleanQuestion(query)
        guard !cleaned.isEmpty else {
            completion(nil)
            return
        }

        searchInternet(query: cleaned, languageCode: languageCode, includePrimarySources: true) { [weak self] answer in
            guard let self else {
                completion(nil)
                return
            }
            if let answer {
                completion(answer)
                return
            }
            self.searchInternetFallbacks(query: cleaned, languageCode: languageCode, completion: completion)
        }
    }

    private func searchInternetFallbacks(
        query: String,
        languageCode: String,
        completion: @escaping (String?) -> Void
    ) {
        let terms = Self.searchTerms(from: query)
        let variants = Self.uniqueQueries([query, terms].filter { !$0.isEmpty })

        tryVariants(variants, index: 0, languageCode: languageCode) { [weak self] answer in
            guard let self else {
                completion(nil)
                return
            }
            if let answer {
                completion(answer)
                return
            }
            self.fetchWebSnippetAnswer(query: query, completion: completion)
        }
    }

    private func fetchWebSnippetAnswer(query: String, completion: @escaping (String?) -> Void) {
        webSnippetSearch.fetchSpokenSnippet(query: query) { snippet in
            guard let snippet else {
                completion(nil)
                return
            }
            if Self.isTimeSensitiveQuery(query) || Self.isAnswerRelevant(snippet, to: query) {
                completion(snippet)
            } else {
                completion(nil)
            }
        }
    }

    static func isTimeSensitiveQuery(_ query: String) -> Bool {
        let normalized = normalize(query)
        let signals = [
            "copa", "mundial", "jogo", "jogos", "placar", "eliminad", "selecao", "brasil",
            "2026", "noticia", "noticias", "hoje", "agora", "atual", "presidente", "campeao",
            "gol", "partida", "adversario", "resultado", "classificacao"
        ]
        return signals.contains { normalized.contains($0) }
    }

    private func tryVariants(
        _ variants: [String],
        index: Int,
        languageCode: String,
        completion: @escaping (String?) -> Void
    ) {
        guard index < variants.count else {
            completion(nil)
            return
        }

        let variant = variants[index]
        fetchExtendedWebAnswer(query: variant, languageCode: languageCode) { [weak self] answer in
            if let answer {
                completion(answer)
                return
            }
            self?.tryVariants(variants, index: index + 1, languageCode: languageCode, completion: completion)
        }
    }

    private static func uniqueQueries(_ queries: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for query in queries {
            let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            result.append(query.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    /// Resolve a melhor query possível para busca na internet a partir de fala não reconhecida.
    static func resolveSearchQuery(from rawText: String) -> String? {
        if let query = searchQuery(from: rawText) {
            return query
        }
        return fallbackSearchQuery(from: rawText)
    }

    /// Extrai termos de busca a partir de fala não reconhecida como comando.
    static func searchQuery(from rawText: String) -> String? {
        let trimmed = stripSpokenPrefix(rawText)
        guard !trimmed.isEmpty else { return nil }

        if let prepared = QuestionPreprocessor.prepare(trimmed) {
            return prepared
        }

        let normalized = normalize(trimmed)
        let greetings: Set<String> = [
            "bom dia", "boa tarde", "boa noite", "oi", "ola", "e ai", "tudo bem",
            "hello", "hi", "good morning", "good night"
        ]
        if greetings.contains(normalized) || nonSearchablePhrases.contains(normalized) {
            return nil
        }

        let terms = searchTerms(from: trimmed)
        if !terms.isEmpty, !greetings.contains(terms) {
            return normalize(trimmed) == terms ? trimmed : terms
        }

        guard normalized.count >= 3 else { return nil }

        return trimmed
    }

    /// Fallback quando a fala não parece pergunta, mas ainda tem conteúdo pesquisável.
    static func fallbackSearchQuery(from rawText: String) -> String? {
        let stripped = stripSpokenPrefix(rawText)
        guard !stripped.isEmpty else { return nil }

        let normalized = normalize(stripped)
        if nonSearchablePhrases.contains(normalized) {
            return nil
        }

        guard normalized.count >= 2 else { return nil }

        return stripped
    }

    private static let nonSearchablePhrases: Set<String> = [
        "bom dia", "boa tarde", "boa noite", "oi", "ola", "e ai", "tudo bem",
        "hello", "hi", "hey", "good morning", "good night", "good afternoon",
        "sim", "nao", "ok", "yes", "no", "yep", "nope",
        "obrigado", "obrigada", "valeu", "brigado", "thanks", "thank you",
        "tchau", "ate logo", "bye", "goodbye"
    ]

    private static func stripSpokenPrefix(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }

        let folded = normalize(result)
        for wake in ["orvia", "or via", "orvya"] where !wake.isEmpty {
            if folded.hasPrefix(wake + " ") {
                let offset = wake.count + 1
                guard let start = result.index(result.startIndex, offsetBy: offset, limitedBy: result.endIndex) else { continue }
                result = String(result[start...])
                break
            } else if folded == wake {
                result = ""
                break
            }
        }

        let fillers = [
            "por favor", "ei", "entao", "olha", "tipo", "assim",
            "please", "so", "well", "um", "uh"
        ]
        var normalized = normalize(result)
        var changed = true
        while changed {
            changed = false
            for filler in fillers.sorted(by: { $0.count > $1.count }) {
                if normalized.hasPrefix(filler + " ") {
                    let offset = filler.count + 1
                    guard let start = result.index(result.startIndex, offsetBy: offset, limitedBy: result.endIndex) else { continue }
                    result = String(result[start...])
                    normalized = normalize(result)
                    changed = true
                    break
                }
                if normalized == filler {
                    result = ""
                    normalized = ""
                    changed = true
                    break
                }
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fetchExtendedWebAnswer(query: String, languageCode: String, completion: @escaping (String?) -> Void) {
        var candidates: [AnswerCandidate] = []
        let group = DispatchGroup()
        let analysis = Self.analyze(question: query)
        let languages = [languageCode, languageCode == "pt" ? "en" : "pt"]
        let queries = Self.uniqueQueries([query, Self.searchTerms(from: query)])

        for searchQuery in queries {
            group.enter()
            fetchDuckDuckGoExtendedAnswer(query: searchQuery) { answer in
                if let answer {
                    candidates.append(AnswerCandidate(
                        text: answer,
                        score: Self.scoreAnswer(answer, analysis: analysis) + 5
                    ))
                }
                group.leave()
            }

            for lang in languages {
                group.enter()
                fetchWikipediaDirectAnswer(query: searchQuery, languageCode: lang) { answer in
                    if let answer {
                        candidates.append(AnswerCandidate(
                            text: answer,
                            score: Self.scoreAnswer(answer, analysis: analysis) + (lang == languageCode ? 8 : 6)
                        ))
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            let relevant = candidates.filter { Self.isAnswerRelevant($0.text, to: query) }
            if let best = relevant.max(by: { $0.score < $1.score }), best.score > 0 {
                completion(Self.trimForSpeech(best.text))
            } else {
                completion(nil)
            }
        }
    }

    private func fetchWikipediaDirectAnswer(query: String, languageCode: String, completion: @escaping (String?) -> Void) {
        guard var components = URLComponents(string: "https://\(languageCode).wikipedia.org/w/api.php") else {
            completion(nil)
            return
        }
        components.queryItems = [
            URLQueryItem(name: "action", value: "opensearch"),
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components.url else {
            completion(nil)
            return
        }

        fetch(url) { [weak self] data in
            guard let self, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  json.count > 1,
                  let titles = json[1] as? [String],
                  let title = titles.first, !title.isEmpty else {
                completion(nil)
                return
            }

            self.fetchWikipediaIntro(title: title, languageCode: languageCode, completion: completion)
        }
    }

    private func fetchWikipediaIntro(title: String, languageCode: String, completion: @escaping (String?) -> Void) {
        guard var components = URLComponents(string: "https://\(languageCode).wikipedia.org/w/api.php") else {
            completion(nil)
            return
        }
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "prop", value: "extracts"),
            URLQueryItem(name: "exintro", value: "1"),
            URLQueryItem(name: "explaintext", value: "1"),
            URLQueryItem(name: "redirects", value: "1"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "titles", value: title)
        ]
        guard let url = components.url else {
            completion(nil)
            return
        }

        fetch(url) { data in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let query = json["query"] as? [String: Any],
                  let pages = query["pages"] as? [String: Any],
                  let page = pages.values.first as? [String: Any],
                  let extract = page["extract"] as? String, !extract.isEmpty else {
                completion(nil)
                return
            }
            completion(Self.firstSentences(of: extract, limit: 2))
        }
    }

    private func fetchDuckDuckGoExtendedAnswer(query: String, completion: @escaping (String?) -> Void) {
        guard var components = URLComponents(string: "https://api.duckduckgo.com/") else {
            completion(nil)
            return
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "0")
        ]
        guard let url = components.url else {
            completion(nil)
            return
        }

        fetch(url) { data in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil)
                return
            }

            let abstract = (json["AbstractText"] as? String) ?? ""
            let answer = (json["Answer"] as? String) ?? ""
            let definition = (json["Definition"] as? String) ?? ""
            let heading = (json["Heading"] as? String) ?? ""

            if let direct = [answer, definition, abstract].first(where: { !$0.isEmpty }) {
                completion(Self.firstSentences(of: direct, limit: 2))
                return
            }

            let related = Self.extractDuckDuckGoRelatedTexts(from: json)
            if let firstRelated = related.first {
                if !heading.isEmpty {
                    completion("\(heading): \(Self.firstSentences(of: firstRelated, limit: 2))")
                } else {
                    completion(Self.firstSentences(of: firstRelated, limit: 2))
                }
                return
            }

            completion(nil)
        }
    }

    private static func extractDuckDuckGoRelatedTexts(from json: [String: Any]) -> [String] {
        guard let related = json["RelatedTopics"] as? [[String: Any]] else { return [] }

        var texts: [String] = []
        for item in related {
            if let text = item["Text"] as? String {
                let cleaned = cleanDuckDuckGoText(text)
                if !cleaned.isEmpty { texts.append(cleaned) }
            }
            if let topics = item["Topics"] as? [[String: Any]] {
                for topic in topics {
                    if let text = topic["Text"] as? String {
                        let cleaned = cleanDuckDuckGoText(text)
                        if !cleaned.isEmpty { texts.append(cleaned) }
                    }
                }
            }
        }
        return texts
    }

    private static func cleanDuckDuckGoText(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dashRange = cleaned.range(of: " - ") {
            cleaned = String(cleaned[dashRange.upperBound...])
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - DuckDuckGo

    private func fetchDuckDuckGoAnswer(query: String, completion: @escaping (String?) -> Void) {
        guard var components = URLComponents(string: "https://api.duckduckgo.com/") else {
            completion(nil)
            return
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1")
        ]
        guard let url = components.url else {
            completion(nil)
            return
        }

        fetch(url) { data in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil)
                return
            }

            let abstract = (json["AbstractText"] as? String) ?? ""
            let answer = (json["Answer"] as? String) ?? ""
            let definition = (json["Definition"] as? String) ?? ""

            let best = [answer, abstract, definition].first { !$0.isEmpty }
            completion(best.map { Self.firstSentences(of: $0, limit: 2) })
        }
    }

    // MARK: - Scoring

    static func scoreAnswer(_ answer: String, analysis: QuestionAnalysis) -> Int {
        scoreAnswer(answer, terms: analysis.coreTerms, intent: analysis.intent)
    }

    static func scoreAnswer(_ answer: String, terms: String, intent: QuestionIntent) -> Int {
        let answerNorm = normalize(answer)
        let stopWords: Set<String> = [
            "voce", "foi", "ser", "por", "quem", "que", "qual", "como", "quando", "onde",
            "para", "com", "dos", "das", "nos", "nas", "uma", "uns", "umas", "seu", "sua",
            "the", "who", "what", "when", "where", "was", "were", "for", "are", "from", "your"
        ]
        let queryWords = Set(searchTerms(from: terms).split(separator: " ").map(String.init))
        let significantWords = queryWords.filter { $0.count > 2 && !stopWords.contains($0) }
        var score = 0
        var overlap = 0

        for word in significantWords {
            if answerNorm.contains(word) {
                score += 12
                overlap += 1
            }
        }

        if significantWords.count >= 2 && overlap == 0 { score -= 60 }
        if significantWords.count >= 3 && overlap < max(1, significantWords.count / 2) { score -= 35 }

        if answer.count >= 25 && answer.count <= 280 { score += 15 }
        if answer.count > 400 { score -= 25 }

        if answerNorm.contains("lista de") || answerNorm.contains("categoria") { score -= 40 }

        switch intent {
        case .who:
            if answerNorm.contains("atual") || answerNorm.contains("titular") || answerNorm.contains(" e ") {
                score += 10
            }
        case .what:
            if answerNorm.contains("e um") || answerNorm.contains("e uma") || answerNorm.contains("processo") {
                score += 8
            }
        case .whereLocation:
            if answerNorm.contains("capital") || answerNorm.contains("localiz") || answerNorm.contains("fica") {
                score += 10
            }
        default:
            break
        }

        return score
    }

    private static func trimForSpeech(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 300 { return trimmed }
        return firstSentences(of: trimmed, limit: 2)
    }

    // MARK: - Helpers

    private func fetch(_ url: URL, completion: @escaping (Data?) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Orvia/1.0 (macOS assistant)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                guard error == nil,
                      let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode) else {
                    completion(nil)
                    return
                }
                completion(data)
            }
        }.resume()
    }

    static func firstSentences(of text: String, limit: Int) -> String {
        let sentences = splitSentences(text)
        if sentences.isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return sentences.prefix(limit).joined(separator: " ")
    }

    static func splitSentences(_ text: String) -> [String] {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var sentences: [String] = []
        var current = ""

        for character in cleaned {
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty {
                    sentences.append(sentence)
                }
                current = ""
            }
        }

        let remainder = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty {
            sentences.append(remainder)
        }
        return sentences
    }

    private static func normalize(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()
            .components(separatedBy: CharacterSet.punctuationCharacters)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let leadingFillers = [
        "por favor", "eu quero saber", "queria saber", "gostaria de saber",
        "sabe me dizer", "pode me dizer", "pode me falar", "me diz", "me diga",
        "me fala", "me fale", "me explica", "quero saber"
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
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func applyTermAliases(_ text: String) -> String {
        var result = text
        let aliases: [(String, String)] = [
            ("braseal", "brasil"), ("presidenti", "presidente"),
            ("fotocintese", "fotossintese"), ("fotosintese", "fotossintese"),
            ("presidente brasil", "presidente do brasil"),
            ("capital brasil", "capital do brasil"),
            ("eua", "estados unidos")
        ]
        for (from, to) in aliases {
            result = result.replacingOccurrences(of: from, with: to)
        }
        return result
    }

    private static func uniqueNonEmpty(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }
}
