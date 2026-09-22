import Foundation

enum ClipboardTextTransform: String, CaseIterable, Identifiable {
    case prettyJSON
    case minifyJSON
    case base64Encode
    case base64Decode
    case upperCase
    case lowerCase
    case camelCase
    case snakeCase
    case trimWhitespace

    var id: String { rawValue }

    func title(for language: AppLanguage) -> String {
        switch self {
        case .prettyJSON:
            return language.text(ptBR: "Formatar JSON", en: "Format JSON")
        case .minifyJSON:
            return language.text(ptBR: "Minificar JSON", en: "Minify JSON")
        case .base64Encode:
            return language.text(ptBR: "Codificar Base64", en: "Encode Base64")
        case .base64Decode:
            return language.text(ptBR: "Decodificar Base64", en: "Decode Base64")
        case .upperCase:
            return language.text(ptBR: "MAIÚSCULAS", en: "UPPERCASE")
        case .lowerCase:
            return language.text(ptBR: "minúsculas", en: "lowercase")
        case .camelCase:
            return "camelCase"
        case .snakeCase:
            return "snake_case"
        case .trimWhitespace:
            return language.text(ptBR: "Remover espaços das bordas", en: "Trim whitespace")
        }
    }
}

enum TextTransformer {
    /// Aplica a transformação; retorna nil se o conteúdo não for compatível.
    static func apply(_ transform: ClipboardTextTransform, to text: String) -> String? {
        switch transform {
        case .prettyJSON:
            return reserializeJSON(text, options: [.prettyPrinted, .sortedKeys])
        case .minifyJSON:
            return reserializeJSON(text, options: [.sortedKeys])
        case .base64Encode:
            return Data(text.utf8).base64EncodedString()
        case .base64Decode:
            guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let decoded = String(data: data, encoding: .utf8) else {
                return nil
            }
            return decoded
        case .upperCase:
            return text.uppercased()
        case .lowerCase:
            return text.lowercased()
        case .camelCase:
            return camelCased(text)
        case .snakeCase:
            return snakeCased(text)
        case .trimWhitespace:
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func isValidJSON(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    private static func reserializeJSON(_ text: String, options: JSONSerialization.WritingOptions) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              JSONSerialization.isValidJSONObject(object) || object is NSNumber || object is NSString || object is NSNull,
              let output = try? JSONSerialization.data(withJSONObject: object, options: options.union(.fragmentsAllowed)),
              let result = String(data: output, encoding: .utf8) else {
            return nil
        }
        return result
    }

    private static func words(from text: String) -> [String] {
        let separators = CharacterSet(charactersIn: " _-\n\t")
        var result: [String] = []

        for chunk in text.components(separatedBy: separators) where !chunk.isEmpty {
            // Divide também por transição de caixa (fooBar -> foo, Bar).
            var current = ""
            for character in chunk {
                if character.isUppercase, !current.isEmpty, current.last?.isLowercase == true {
                    result.append(current)
                    current = String(character)
                } else {
                    current.append(character)
                }
            }
            if !current.isEmpty {
                result.append(current)
            }
        }

        return result
    }

    private static func camelCased(_ text: String) -> String? {
        let parts = words(from: text)
        guard !parts.isEmpty else { return nil }

        let head = parts[0].lowercased()
        let tail = parts.dropFirst().map { $0.lowercased().capitalizedFirst }
        return ([head] + tail).joined()
    }

    private static func snakeCased(_ text: String) -> String? {
        let parts = words(from: text)
        guard !parts.isEmpty else { return nil }
        return parts.map { $0.lowercased() }.joined(separator: "_")
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }
}
