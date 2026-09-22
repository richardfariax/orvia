import Foundation
import OSLog

/// Captura de tela via `screencapture` do sistema, direto para o clipboard.
/// O ClipboardMonitorService captura o resultado e salva no histórico.
@MainActor
final class ScreenshotService {
    enum Mode {
        case fullScreen
        case interactiveArea

        var arguments: [String] {
            switch self {
            case .fullScreen:
                return ["-c"]
            case .interactiveArea:
                return ["-i", "-c"]
            }
        }
    }

    func capture(_ mode: Mode, completion: @escaping (Bool) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = mode.arguments

        process.terminationHandler = { finished in
            DispatchQueue.main.async {
                completion(finished.terminationStatus == 0)
            }
        }

        do {
            try process.run()
        } catch {
            Logger(subsystem: "com.richadfarias.orvia", category: "assistant").error("[Orvia] Falha ao executar screencapture: \(error.localizedDescription)")
            completion(false)
        }
    }
}
