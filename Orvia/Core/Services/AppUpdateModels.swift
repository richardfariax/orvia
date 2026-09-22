import Foundation

struct AppUpdateRelease: Equatable, Sendable {
    let version: String
    let title: String
    let notes: String
    let htmlURL: URL
    let zipURL: URL
    let sha256URL: URL?
    let zipByteCount: Int
    let publishedAt: Date?
}

struct AppUpdateProgress: Equatable {
    enum Stage: Equatable {
        case checking
        case downloading
        case verifying
        case extracting
        case installing
    }

    var stage: Stage
    /// Progresso da etapa atual (0...1). `-1` = indeterminado.
    var stageFraction: Double
    var bytesReceived: Int64
    var bytesTotal: Int64

    /// Progresso global ponderado do pipeline (0...1).
    var overallFraction: Double {
        let stageProgress = stageFraction < 0 ? 0 : min(max(stageFraction, 0), 1)
        switch stage {
        case .checking:
            return 0.02
        case .downloading:
            return 0.05 + (0.70 * stageProgress)
        case .verifying:
            return 0.75 + (0.08 * stageProgress)
        case .extracting:
            return 0.83 + (0.12 * stageProgress)
        case .installing:
            return 0.95 + (0.05 * stageProgress)
        }
    }

    static func checking() -> AppUpdateProgress {
        AppUpdateProgress(stage: .checking, stageFraction: -1, bytesReceived: 0, bytesTotal: 0)
    }

    static func downloading(received: Int64, total: Int64) -> AppUpdateProgress {
        let fraction: Double
        if total > 0 {
            fraction = Double(received) / Double(total)
        } else {
            fraction = -1
        }
        return AppUpdateProgress(
            stage: .downloading,
            stageFraction: fraction,
            bytesReceived: received,
            bytesTotal: total
        )
    }
}

enum AppUpdatePhase: Equatable {
    case idle
    case checking
    case upToDate
    case available(AppUpdateRelease)
    case updating(AppUpdateRelease, AppUpdateProgress)
    case failed(String, release: AppUpdateRelease?)

    var availableRelease: AppUpdateRelease? {
        switch self {
        case .available(let release), .updating(let release, _):
            return release
        case .failed(_, let release):
            return release
        case .idle, .checking, .upToDate:
            return nil
        }
    }

    var progress: AppUpdateProgress? {
        if case .updating(_, let progress) = self {
            return progress
        }
        return nil
    }

    var isBusy: Bool {
        switch self {
        case .checking, .updating:
            return true
        case .idle, .upToDate, .available, .failed:
            return false
        }
    }

    var canCancel: Bool {
        if case .updating(_, let progress) = self {
            return progress.stage == .downloading
        }
        return false
    }
}

enum AppUpdateError: LocalizedError, Equatable {
    case invalidRepository
    case network(String)
    case httpStatus(Int)
    case noZipAsset
    case decodeFailed
    case runningFromDerivedData
    case missingBundlePath
    case checksumMismatch
    case checksumUnavailable
    case invalidPackage
    case bundleIdentifierMismatch
    case invalidSignature
    case installScriptFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidRepository:
            return "Invalid GitHub repository."
        case .network(let message):
            return message
        case .httpStatus(let code):
            return "GitHub returned HTTP \(code)."
        case .noZipAsset:
            return "Release has no Orvia.zip asset."
        case .decodeFailed:
            return "Could not parse GitHub release metadata."
        case .runningFromDerivedData:
            return "Updates require the installed Orvia.app, not an Xcode/DerivedData build."
        case .missingBundlePath:
            return "Could not resolve the current app path."
        case .checksumMismatch:
            return "Downloaded update failed SHA-256 verification."
        case .checksumUnavailable:
            return "Release is missing Orvia.zip.sha256."
        case .invalidPackage:
            return "Update package does not contain Orvia.app."
        case .bundleIdentifierMismatch:
            return "Update package bundle identifier does not match Orvia."
        case .invalidSignature:
            return "Update signature is invalid or does not match the installed app."
        case .installScriptFailed:
            return "Could not start the install helper."
        case .cancelled:
            return "Update cancelled."
        }
    }
}
