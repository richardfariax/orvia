import AppKit
import CryptoKit
import Foundation
import Security

/// Atualização in-app via GitHub Releases.
/// Substitui o `.app` no **mesmo path** (melhor chance de preservar TCC).
@MainActor
final class AppUpdateService: ObservableObject {
    @Published private(set) var phase: AppUpdatePhase = .idle
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var automaticChecksEnabled: Bool

    private let settings: AppSettings
    private let repo: String
    private let session: URLSession
    private var downloadDelegate: UpdateDownloadSession?
    private var activeDownloadTask: URLSessionDownloadTask?
    private var activeDownloadSession: URLSession?
    private var cancelRequested = false

    private let defaults = UserDefaults.standard
    private let lastCheckedKey = "orvia.updates.lastCheckedAt"
    private let automaticChecksKey = "orvia.updates.automaticChecksEnabled"
    private let minimumCheckInterval: TimeInterval = 60 * 60 * 12

    init(settings: AppSettings, repo: String = DeveloperProfileCatalog.githubRepo) {
        self.settings = settings
        self.repo = repo
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 10
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
        self.automaticChecksEnabled = defaults.object(forKey: automaticChecksKey) as? Bool ?? true
        if let interval = defaults.object(forKey: lastCheckedKey) as? TimeInterval {
            self.lastCheckedAt = Date(timeIntervalSince1970: interval)
        }
    }

    var hasUpdateAvailable: Bool {
        phase.availableRelease != nil && !phase.isBusy
    }

    func setAutomaticChecksEnabled(_ enabled: Bool) {
        automaticChecksEnabled = enabled
        defaults.set(enabled, forKey: automaticChecksKey)
    }

    func checkForUpdatesIfNeededOnLaunch() {
        guard automaticChecksEnabled else { return }
        if let lastCheckedAt, Date().timeIntervalSince(lastCheckedAt) < minimumCheckInterval {
            return
        }
        Task { await checkForUpdates(userInitiated: false) }
    }

    func checkForUpdates(userInitiated: Bool = true) async {
        guard !phase.isBusy else { return }

        if isRunningFromDerivedData {
            if userInitiated {
                phase = .failed(localizedError(.runningFromDerivedData), release: nil)
            }
            return
        }

        phase = .checking
        cancelRequested = false

        do {
            let release = try await fetchLatestRelease()
            lastCheckedAt = Date()
            defaults.set(lastCheckedAt?.timeIntervalSince1970, forKey: lastCheckedKey)

            if AppVersion.isNewer(release.version, than: AppVersion.marketing) {
                phase = .available(release)
            } else {
                phase = .upToDate
            }
        } catch let error as AppUpdateError {
            phase = userInitiated ? .failed(localizedError(error), release: nil) : .idle
        } catch {
            phase = userInitiated
                ? .failed(error.localizedDescription, release: nil)
                : .idle
        }
    }

    func installAvailableUpdate() async {
        guard case .available(let release) = phase else { return }
        await downloadAndInstall(release)
    }

    func cancel() {
        guard phase.canCancel else { return }
        cancelRequested = true
        activeDownloadTask?.cancel()
        activeDownloadSession?.invalidateAndCancel()
        if let release = phase.availableRelease {
            phase = .available(release)
        } else {
            phase = .idle
        }
    }

    func openReleasePage() {
        guard let release = phase.availableRelease else {
            if let url = URL(string: "\(DeveloperProfileCatalog.githubURL)/releases/latest") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        NSWorkspace.shared.open(release.htmlURL)
    }

    // MARK: - Network

    private func fetchLatestRelease() async throws -> AppUpdateRelease {
        guard !repo.isEmpty, repo.contains("/") else {
            throw AppUpdateError.invalidRepository
        }

        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw AppUpdateError.invalidRepository
        }

        var request = URLRequest(url: url)
        request.setValue("Orvia/\(AppVersion.marketing) (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AppUpdateError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AppUpdateError.network("Invalid response.")
        }
        guard (200...299).contains(http.statusCode) else {
            throw AppUpdateError.httpStatus(http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dto: GitHubReleaseDTO
        do {
            dto = try decoder.decode(GitHubReleaseDTO.self, from: data)
        } catch {
            throw AppUpdateError.decodeFailed
        }

        guard let zip = dto.assets.first(where: { $0.name == "Orvia.zip" }) else {
            throw AppUpdateError.noZipAsset
        }
        guard let zipURL = URL(string: zip.browserDownloadURL) else {
            throw AppUpdateError.noZipAsset
        }

        let shaAsset = dto.assets.first(where: { $0.name == "Orvia.zip.sha256" })
        let shaURL = shaAsset.flatMap { URL(string: $0.browserDownloadURL) }

        let version = dto.tagName.hasPrefix("v") ? String(dto.tagName.dropFirst()) : dto.tagName
        return AppUpdateRelease(
            version: version,
            title: dto.name?.isEmpty == false ? (dto.name ?? version) : "Orvia \(version)",
            notes: dto.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            htmlURL: URL(string: dto.htmlURL) ?? zipURL,
            zipURL: zipURL,
            sha256URL: shaURL,
            zipByteCount: zip.size,
            publishedAt: dto.publishedAt
        )
    }

    // MARK: - Download + install

    private func downloadAndInstall(_ release: AppUpdateRelease) async {
        if isRunningFromDerivedData {
            phase = .failed(localizedError(.runningFromDerivedData), release: release)
            return
        }

        let currentAppURL = Bundle.main.bundleURL
        guard currentAppURL.pathExtension == "app" else {
            phase = .failed(localizedError(.missingBundlePath), release: release)
            return
        }

        cancelRequested = false
        let expectedBytes = Int64(max(release.zipByteCount, 0))
        phase = .updating(release, .downloading(received: 0, total: expectedBytes))

        do {
            let workingDirectory = try makeWorkingDirectory(for: release.version)
            let zipURL = workingDirectory.appendingPathComponent("Orvia.zip")

            try await download(release.zipURL, to: zipURL, expectedBytes: expectedBytes) { [weak self] received, total in
                Task { @MainActor in
                    guard let self, !self.cancelRequested else { return }
                    self.phase = .updating(release, .downloading(received: received, total: total))
                }
            }

            try throwIfCancelled()

            phase = .updating(
                release,
                AppUpdateProgress(stage: .verifying, stageFraction: 0.15, bytesReceived: 0, bytesTotal: 0)
            )

            guard let shaURL = release.sha256URL else { throw AppUpdateError.checksumUnavailable }
            let expected = try await fetchChecksum(from: shaURL)
            try throwIfCancelled()
            phase = .updating(
                release,
                AppUpdateProgress(stage: .verifying, stageFraction: 0.55, bytesReceived: 0, bytesTotal: 0)
            )
            let actual = try await Task.detached(priority: .userInitiated) {
                try Self.sha256Hex(ofFileAt: zipURL)
            }.value
            guard actual.lowercased() == expected.lowercased() else {
                throw AppUpdateError.checksumMismatch
            }

            phase = .updating(
                release,
                AppUpdateProgress(stage: .verifying, stageFraction: 1, bytesReceived: 0, bytesTotal: 0)
            )
            try throwIfCancelled()

            phase = .updating(
                release,
                AppUpdateProgress(stage: .extracting, stageFraction: 0.2, bytesReceived: 0, bytesTotal: 0)
            )

            let extractedApp = try await Task.detached(priority: .userInitiated) {
                try Self.extractApp(from: zipURL, into: workingDirectory)
            }.value

            phase = .updating(
                release,
                AppUpdateProgress(stage: .extracting, stageFraction: 0.85, bytesReceived: 0, bytesTotal: 0)
            )
            try Self.validate(extractedApp: extractedApp)
            phase = .updating(
                release,
                AppUpdateProgress(stage: .extracting, stageFraction: 1, bytesReceived: 0, bytesTotal: 0)
            )

            phase = .updating(
                release,
                AppUpdateProgress(stage: .installing, stageFraction: 0.4, bytesReceived: 0, bytesTotal: 0)
            )
            try launchInstallHelper(
                currentAppURL: currentAppURL,
                replacementAppURL: extractedApp
            )
            phase = .updating(
                release,
                AppUpdateProgress(stage: .installing, stageFraction: 1, bytesReceived: 0, bytesTotal: 0)
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSApp.terminate(nil)
            }
        } catch let error as AppUpdateError {
            if error == .cancelled {
                phase = .available(release)
            } else {
                phase = .failed(localizedError(error), release: release)
            }
        } catch is CancellationError {
            phase = .available(release)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                phase = .available(release)
            } else {
                phase = .failed(error.localizedDescription, release: release)
            }
        }
    }

    private func download(
        _ remoteURL: URL,
        to localURL: URL,
        expectedBytes: Int64,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = UpdateDownloadSession(
                destinationURL: localURL,
                expectedBytes: expectedBytes,
                onProgress: onProgress,
                continuation: continuation
            )
            self.downloadDelegate = delegate
            let downloadSession = URLSession(
                configuration: session.configuration,
                delegate: delegate,
                delegateQueue: nil
            )
            self.activeDownloadSession = downloadSession
            var request = URLRequest(url: remoteURL)
            request.setValue("Orvia/\(AppVersion.marketing) (macOS)", forHTTPHeaderField: "User-Agent")
            let task = downloadSession.downloadTask(with: request)
            self.activeDownloadTask = task
            task.resume()
        }
        downloadDelegate = nil
        activeDownloadTask = nil
        activeDownloadSession = nil
    }

    private func fetchChecksum(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("Orvia/\(AppVersion.marketing) (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AppUpdateError.checksumUnavailable
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw AppUpdateError.checksumUnavailable
        }
        let token = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .first
            .map(String.init)?
            .lowercased()
        guard let token, token.count == 64, token.allSatisfy(\.isHexDigit) else {
            throw AppUpdateError.checksumUnavailable
        }
        return token
    }

    private nonisolated static func extractApp(from zipURL: URL, into directory: URL) throws -> URL {
        let extractDir = directory.appendingPathComponent("payload", isDirectory: true)
        try? FileManager.default.removeItem(at: extractDir)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, extractDir.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AppUpdateError.invalidPackage
        }

        let appURL = extractDir.appendingPathComponent("Orvia.app", isDirectory: true)
        if FileManager.default.fileExists(atPath: appURL.path) {
            return appURL
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: extractDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        if let found = contents.first(where: { $0.pathExtension == "app" }) {
            return found
        }
        throw AppUpdateError.invalidPackage
    }

    private nonisolated static func validate(extractedApp: URL) throws {
        let plistURL = extractedApp.appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOf: plistURL) as? [String: Any] else {
            throw AppUpdateError.invalidPackage
        }
        let expectedID = Bundle.main.bundleIdentifier
        let packageID = plist["CFBundleIdentifier"] as? String
        guard let expectedID, packageID == expectedID else {
            throw AppUpdateError.bundleIdentifierMismatch
        }
        guard let currentTeam = signingTeamID(for: Bundle.main.bundleURL),
              let packageTeam = signingTeamID(for: extractedApp),
              currentTeam == packageTeam else {
            throw AppUpdateError.invalidSignature
        }
    }

    private nonisolated static func signingTeamID(for appURL: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information,
              let teamID = (information as NSDictionary)[kSecCodeInfoTeamIdentifier as String] as? String,
              !teamID.isEmpty else {
            return nil
        }
        return teamID
    }

    private func launchInstallHelper(currentAppURL: URL, replacementAppURL: URL) throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let scriptsDir = support.appendingPathComponent("Orvia/Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)

        let scriptURL = scriptsDir.appendingPathComponent("install-update.sh")
        let logURL = scriptsDir.appendingPathComponent("install-update.log")

        let script = """
        #!/bin/bash
        set -euo pipefail
        APP_PATH="$1"
        NEW_APP="$2"
        LOG_PATH="$3"
        exec >>"$LOG_PATH" 2>&1
        echo "[$(date)] Orvia update helper starting"
        echo "APP_PATH=$APP_PATH"
        echo "NEW_APP=$NEW_APP"

        for _ in $(seq 1 100); do
          if ! pgrep -f "$APP_PATH/Contents/MacOS/Orvia" >/dev/null 2>&1; then
            break
          fi
          sleep 0.2
        done
        sleep 0.4

        BACKUP="${APP_PATH}.orvia-backup"
        rm -rf "$BACKUP"
        if [[ -d "$APP_PATH" ]]; then
          mv "$APP_PATH" "$BACKUP"
        fi

        mv "$NEW_APP" "$APP_PATH"
        xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true

        if [[ -d "$BACKUP" ]]; then
          rm -rf "$BACKUP"
        fi

        echo "[$(date)] Launching updated app"
        open "$APP_PATH"
        echo "[$(date)] Done"
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            scriptURL.path,
            currentAppURL.path,
            replacementAppURL.path,
            logURL.path
        ]
        process.standardOutput = nil
        process.standardError = nil
        do {
            try process.run()
        } catch {
            throw AppUpdateError.installScriptFailed
        }
    }

    private func makeWorkingDirectory(for version: String) throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = caches
            .appendingPathComponent("Orvia/Updates", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var isRunningFromDerivedData: Bool {
        Bundle.main.bundlePath.contains("DerivedData")
    }

    private func throwIfCancelled() throws {
        if cancelRequested {
            throw AppUpdateError.cancelled
        }
    }

    private func localizedError(_ error: AppUpdateError) -> String {
        settings.text(
            ptBR: portugueseMessage(for: error),
            en: error.errorDescription ?? "Update failed."
        )
    }

    private func portugueseMessage(for error: AppUpdateError) -> String {
        switch error {
        case .invalidRepository:
            return "Repositório GitHub inválido."
        case .network(let message):
            return message
        case .httpStatus(let code):
            return "GitHub retornou HTTP \(code)."
        case .noZipAsset:
            return "A release não tem o asset Orvia.zip."
        case .decodeFailed:
            return "Não foi possível ler os dados da release."
        case .runningFromDerivedData:
            return "Atualizações só funcionam no Orvia.app instalado, não no build do Xcode."
        case .missingBundlePath:
            return "Não foi possível localizar o app atual."
        case .checksumMismatch:
            return "A atualização falhou na verificação SHA-256."
        case .checksumUnavailable:
            return "A release não tem Orvia.zip.sha256."
        case .invalidPackage:
            return "O pacote não contém Orvia.app."
        case .bundleIdentifierMismatch:
            return "O pacote não é o Orvia (bundle id diferente)."
        case .invalidSignature:
            return "A assinatura da atualização é inválida ou não corresponde à instalação atual."
        case .installScriptFailed:
            return "Não foi possível iniciar o instalador."
        case .cancelled:
            return "Atualização cancelada."
        }
    }

    private nonisolated static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - GitHub DTO

private struct GitHubReleaseDTO: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: String
    let publishedAt: Date?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case assets
    }

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String
        let size: Int

        enum CodingKeys: String, CodingKey {
            case name
            case size
            case browserDownloadURL = "browser_download_url"
        }
    }
}

// MARK: - Download delegate

private final class UpdateDownloadSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destinationURL: URL
    private let expectedBytes: Int64
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let continuation: CheckedContinuation<Void, Error>
    private var finished = false

    init(
        destinationURL: URL,
        expectedBytes: Int64,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        continuation: CheckedContinuation<Void, Error>
    ) {
        self.destinationURL = destinationURL
        self.expectedBytes = expectedBytes
        self.onProgress = onProgress
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
        onProgress(totalBytesWritten, total)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)
            let size = (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            onProgress(size, max(expectedBytes, size))
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        }
        session.finishTasksAndInvalidate()
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
