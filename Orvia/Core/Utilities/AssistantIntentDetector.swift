import Foundation

/// Detecta ações explícitas ligadas ao perfil do desenvolvedor (abrir LinkedIn).
/// Conversa sobre identidade/ajuda vai para a IA — não para intenções fixas.
enum AssistantIntentDetector {
    static func isDeveloperProfileRequest(_ normalized: String) -> Bool {
        let developerWords = [
            "dono", "criador", "desenvolvedor", "richard", "seu", "dele",
            "developer", "creator", "owner", "your"
        ]
        return normalized.contains("linkedin")
            && developerWords.contains(where: { normalized.contains($0) })
    }
}
