import AppKit
import CoreGraphics
import Foundation
import OSLog
import ScreenCaptureKit
import Vision

enum ScreenAnalysisError: Error {
    case captureFailed
    case permissionDenied
    case noTextFound
}

/// Captura a tela principal e extrai texto visível com Vision (OCR local).
final class ScreenAnalysisService {
    private let maxSpokenCharacters = 420
    private let maxLines = 10

    /// - Parameters:
    ///   - languageCode: "pt" ou "en" — idioma preferido do OCR.
    ///   - onPrepareCapture: chamado antes da captura (ex.: esconder overlay do Orvia).
    ///   - completion: descrição falada do conteúdo visível.
    func describeVisibleScreen(
        languageCode: String,
        onPrepareCapture: @escaping () -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        onPrepareCapture()

        // Aguarda o HUD sumir antes de capturar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }

            Task {
                guard let image = await Self.captureMainDisplayImage() else {
                    Self.requestScreenCaptureAccessIfNeeded()
                    completion(.failure(ScreenAnalysisError.permissionDenied))
                    return
                }

                let appName = Self.frontmostApplicationName()
                let ocrLanguages = Self.ocrLanguages(for: languageCode)
                let maxLines = self.maxLines
                let maxCharacters = self.maxSpokenCharacters

                let lines = await Task.detached(priority: .userInitiated) {
                    Self.recognizeText(in: image, languages: ocrLanguages)
                }.value

                let description = Self.buildDescription(
                    appName: appName,
                    lines: lines,
                    languageCode: languageCode,
                    maxLines: maxLines,
                    maxCharacters: maxCharacters
                )

                if let description {
                    completion(.success(description))
                } else {
                    completion(.failure(ScreenAnalysisError.noTextFound))
                }
            }
        }
    }

    static func requestScreenCaptureAccessIfNeeded() {
        if #available(macOS 10.15, *) {
            _ = CGRequestScreenCaptureAccess()
        }
    }

    // MARK: - Capture

    private static func captureMainDisplayImage() async -> CGImage? {
        if let image = await captureWithScreenCaptureKit() {
            return image
        }
        return captureWithScreencaptureCLI()
    }

    private static func captureWithScreenCaptureKit() async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return nil }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(display.width) * 2
            config.height = Int(display.height) * 2
            config.showsCursor = false

            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            Logger(subsystem: "com.richadfarias.orvia", category: "assistant").error("[Orvia] ScreenCaptureKit falhou: \(error.localizedDescription)")
            return nil
        }
    }

    /// Fallback via utilitário do sistema — útil quando CGPreflight falha mas a permissão existe.
    private static func captureWithScreencaptureCLI() -> CGImage? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("orvia-screen-\(UUID().uuidString).png")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-t", "png", tempURL.path]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Logger(subsystem: "com.richadfarias.orvia", category: "assistant").error("[Orvia] screencapture falhou: \(error.localizedDescription)")
            return nil
        }

        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard process.terminationStatus == 0,
              let nsImage = NSImage(contentsOf: tempURL),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        return cgImage
    }

    private static func frontmostApplicationName() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return nil
        }
        return app.localizedName
    }

    // MARK: - OCR

    private struct RecognizedLine {
        let text: String
        let confidence: Float
        let y: CGFloat
    }

    private static func ocrLanguages(for languageCode: String) -> [String] {
        if languageCode.lowercased().hasPrefix("pt") {
            return ["pt-BR", "en-US"]
        }
        return ["en-US", "pt-BR"]
    }

    private static func recognizeText(in image: CGImage, languages: [String]) -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            Logger(subsystem: "com.richadfarias.orvia", category: "assistant").error("[Orvia] OCR falhou: \(error.localizedDescription)")
            return []
        }

        guard let observations = request.results else {
            return []
        }

        var lines: [RecognizedLine] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence > 0.2 else { continue }

            let trimmed = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { continue }

            lines.append(RecognizedLine(
                text: trimmed,
                confidence: candidate.confidence,
                y: 1 - observation.boundingBox.midY
            ))
        }

        return lines
            .sorted { lhs, rhs in
                if abs(lhs.y - rhs.y) < 0.02 {
                    return lhs.confidence > rhs.confidence
                }
                return lhs.y < rhs.y
            }
    }

    // MARK: - Description

    private static func buildDescription(
        appName: String?,
        lines: [RecognizedLine],
        languageCode: String,
        maxLines: Int,
        maxCharacters: Int
    ) -> String? {
        var uniqueLines: [String] = []
        var seen: Set<String> = []

        for line in lines {
            let key = line.text.folding(options: .diacriticInsensitive, locale: .current).lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            uniqueLines.append(line.text)
            if uniqueLines.count >= maxLines { break }
        }

        let isPortuguese = languageCode.lowercased().hasPrefix("pt")

        if uniqueLines.isEmpty {
            if let appName {
                return isPortuguese
                    ? "Estou vendo o \(appName), mas não encontrei texto legível na tela."
                    : "I'm looking at \(appName), but I couldn't find readable text on the screen."
            }
            return isPortuguese
                ? "Não encontrei texto legível na tela."
                : "I couldn't find readable text on the screen."
        }

        var body = uniqueLines.joined(separator: ". ")
        if body.count > maxCharacters {
            body = String(body.prefix(maxCharacters))
            if let lastSpace = body.lastIndex(of: " ") {
                body = String(body[..<lastSpace])
            }
            body += "..."
        }

        if let appName {
            return isPortuguese
                ? "Na tela do \(appName), leio: \(body)."
                : "On \(appName)'s screen, I read: \(body)."
        }

        return isPortuguese
            ? "Na tela, leio: \(body)."
            : "On screen, I read: \(body)."
    }
}
