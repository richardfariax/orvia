import Foundation

/// Catálogo central de frases, atalhos e textos de ajuda do assistente Orvia.
enum VoiceCommandCatalog {
  // MARK: - Sites conhecidos

  static let websiteAliases: [String: String] = [
    "youtube": "youtube.com",
    "google": "google.com",
    "gmail": "gmail.com",
    "github": "github.com",
    "twitter": "twitter.com",
    "x": "x.com",
    "instagram": "instagram.com",
    "facebook": "facebook.com",
    "whatsapp": "web.whatsapp.com",
    "linkedin": "linkedin.com",
    "reddit": "reddit.com",
    "stackoverflow": "stackoverflow.com",
    "wikipedia": "wikipedia.org",
    "notion": "notion.so",
    "figma": "figma.com",
    "spotify": "open.spotify.com",
    "netflix": "netflix.com",
    "amazon": "amazon.com.br",
    "mercado livre": "mercadolivre.com.br",
  ]

  // MARK: - Pastas do sistema

  enum Folder: String, CaseIterable {
    case downloads
    case desktop
    case documents
    case home

    var url: URL {
      let fm = FileManager.default
      switch self {
      case .downloads: return fm.urls(for: .downloadsDirectory, in: .userDomainMask).first!
      case .desktop: return fm.urls(for: .desktopDirectory, in: .userDomainMask).first!
      case .documents: return fm.urls(for: .documentDirectory, in: .userDomainMask).first!
      case .home: return fm.homeDirectoryForCurrentUser
      }
    }

    static func match(_ normalized: String) -> Folder? {
      let map: [(Folder, [String])] = [
        (.downloads, ["downloads", "download", "baixados", "pasta de downloads", "pasta downloads"]),
        (.desktop, ["desktop", "area de trabalho", "área de trabalho", "mesa"]),
        (.documents, ["documents", "documentos", "pasta de documentos", "pasta documentos"]),
        (.home, ["home", "inicio", "início", "pasta do usuario", "pasta do usuário", "minha pasta"]),
      ]
      for (folder, phrases) in map where phrases.contains(where: { normalized.contains($0) }) {
        return folder
      }
      return nil
    }

    func spokenName(pt: Bool) -> String {
      switch self {
      case .downloads: return pt ? "Downloads" : "Downloads"
      case .desktop: return pt ? "Área de Trabalho" : "Desktop"
      case .documents: return pt ? "Documentos" : "Documents"
      case .home: return pt ? "sua pasta pessoal" : "your home folder"
      }
    }
  }

  // MARK: - Matemática simples

  /// Converte fala em expressão numérica e avalia.
  static func evaluateMath(_ normalized: String) -> String? {
    var expr = normalized
    let prefixes = [
      "quanto e", "quanto da", "calcule", "calcula", "calcular", "resultado de",
      "what is", "what's", "calculate",
    ]
    for prefix in prefixes where expr.hasPrefix(prefix + " ") {
      expr = String(expr.dropFirst(prefix.count + 1))
      break
    }

    let replacements: [(String, String)] = [
      (" dividido por ", "/"), (" dividido em ", "/"), (" sobre ", "/"),
      (" vezes ", "*"), (" x ", "*"), (" multiplicado por ", "*"),
      (" mais ", "+"), (" menos ", "-"), (" por cento", ""),
      ("mais", "+"), ("menos", "-"), ("vezes", "*"), ("dividido por", "/"),
    ]
    for (from, to) in replacements {
      expr = expr.replacingOccurrences(of: from, with: to)
    }

    expr = expr
      .replacingOccurrences(of: ",", with: ".")
      .replacingOccurrences(of: " ", with: "")

    guard !expr.isEmpty,
          expr.allSatisfy({ "0123456789+-*/().".contains($0) }) else {
      return nil
    }

    let nsExpr = NSExpression(format: expr)
    guard let value = nsExpr.expressionValue(with: nil, context: nil) as? NSNumber else {
      return nil
    }

    let double = value.doubleValue
    if double.truncatingRemainder(dividingBy: 1) == 0 {
      return String(Int(double))
    }
    return String(format: "%.2f", double)
  }
}
