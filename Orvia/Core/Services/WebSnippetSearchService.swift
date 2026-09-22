import Foundation

/// Busca trechos na web via DuckDuckGo Lite (gratuito, sem chave de API).
/// Complementa Wikipedia/Wikidata para notícias e fatos recentes (copa, política, etc.).
final class WebSnippetSearchService {
    private let timeout: TimeInterval = 8

    func fetchSpokenSnippet(query: String, completion: @escaping (String?) -> Void) {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            completion(nil)
            return
        }

        fetchDuckDuckGoLiteSnippet(query: cleaned) { [weak self] snippet in
            if let snippet {
                completion(Self.trimForSpeech(snippet))
                return
            }
            self?.fetchDuckDuckGoNewsSnippet(query: cleaned, completion: completion)
        }
    }

    // MARK: - DuckDuckGo Lite

    private func fetchDuckDuckGoLiteSnippet(query: String, completion: @escaping (String?) -> Void) {
        guard var components = URLComponents(string: "https://lite.duckduckgo.com/lite/") else {
            completion(nil)
            return
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else {
            completion(nil)
            return
        }

        fetchHTML(url) { html in
            completion(html.flatMap(Self.parseLiteSnippet))
        }
    }

    private func fetchDuckDuckGoNewsSnippet(query: String, completion: @escaping (String?) -> Void) {
        guard var components = URLComponents(string: "https://duckduckgo.com/") else {
            completion(nil)
            return
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "iar", value: "news"),
            URLQueryItem(name: "ia", value: "news")
        ]
        guard let url = components.url else {
            completion(nil)
            return
        }

        fetchHTML(url) { html in
            completion(html.flatMap { Self.parseGenericSnippet($0) })
        }
    }

    // MARK: - Parsing

    private static func parseLiteSnippet(_ html: String) -> String? {
        let pattern = #"<td[^>]*class="result-snippet"[^>]*>([\s\S]*?)</td>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              let snippetRange = Range(match.range(at: 1), in: html) else {
            return nil
        }

        return cleanHTML(String(html[snippetRange]))
    }

    private static func parseGenericSnippet(_ html: String) -> String? {
        let patterns = [
            #"<a[^>]*class="result__snippet"[^>]*>([\s\S]*?)</a>"#,
            #"<div[^>]*class="[^"]*snippet[^"]*"[^>]*>([\s\S]*?)</div>"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                continue
            }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            if let match = regex.firstMatch(in: html, options: [], range: range),
               let snippetRange = Range(match.range(at: 1), in: html) {
                let cleaned = cleanHTML(String(html[snippetRange]))
                if cleaned.count >= 30 { return cleaned }
            }
        }
        return nil
    }

    private static func cleanHTML(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        return text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimForSpeech(_ text: String) -> String {
        if text.count <= 320 { return text }
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let joined = sentences.prefix(2).joined(separator: ". ")
        return joined.isEmpty ? String(text.prefix(300)) : joined + "."
    }

    // MARK: - Network

    private func fetchHTML(_ url: URL, completion: @escaping (String?) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Orvia/1.0",
            forHTTPHeaderField: "User-Agent"
        )

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                guard error == nil,
                      let http = response as? HTTPURLResponse,
                      (200..<400).contains(http.statusCode),
                      let data,
                      let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                    completion(nil)
                    return
                }
                completion(html)
            }
        }.resume()
    }
}
