import Foundation
import OSLog
import SQLite3

/// One-time transfer from the previous installation. The old files remain untouched.
enum LegacyMigration {
    private static let logger = Logger(subsystem: "com.richadfarias.orvia", category: "migration")
    private static let versionKey = "migrationVersion"
    private static let clipboardVersionKey = "clipboardMigrationVersion"
    private static let version = 1
    private static let oldBundleID = "com.richadfarias.clipflow"

    static func migratePreferences(
        to defaults: UserDefaults = .standard,
        from legacyDefaults: UserDefaults? = UserDefaults(suiteName: oldBundleID)
    ) {
        guard defaults.integer(forKey: versionKey) < version else { return }
        guard let oldDefaults = legacyDefaults else { return }
        let keys = [
            "historyLimit", "historyRetentionDays", "pauseMonitoring", "enableEncryption", "ignoredBundleIDs",
            "hotkeyCode", "hotkeyModifiers", "launchAtLogin", "appearance", "language",
            "voiceControlEnabled", "voiceWakeWord", "voiceSoundFeedback",
            "voiceActivationMode", "voiceSpokenResponses", "generativeAnswersEnabled",
            "generativeUseWebContext", "userName", "menuBarMetricStyles", "metricsPopoverMode"
        ]
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = oldDefaults.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(version, forKey: versionKey)
        logger.info("Preference migration completed")
    }

    static func migrateClipboardStore(
        to destination: URL,
        from sourceOverride: URL? = nil,
        defaults: UserDefaults = .standard
    ) throws {
        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let source = sourceOverride ?? support.appendingPathComponent("default.store")
        guard fileManager.fileExists(atPath: source.path) else { return }
        let destinationExists = fileManager.fileExists(atPath: destination.path)
        if destinationExists && defaults.integer(forKey: clipboardVersionKey) >= version { return }
        if destinationExists {
            let existingCount = try clipboardItemCount(in: destination)
            if existingCount > 0 {
                defaults.set(version, forKey: clipboardVersionKey)
                return
            }
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        var sourceDB: OpaquePointer?
        defer {
            if let sourceDB { sqlite3_close(sourceDB) }
        }
        guard sqlite3_open_v2(source.path, &sourceDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let sourceDB else {
            throw MigrationError.cannotOpenLegacyStore
        }

        var statement: OpaquePointer?
        let query = "SELECT name FROM sqlite_master WHERE type='table' AND name='ZCLIPBOARDITEMENTITY'"
        guard sqlite3_prepare_v2(sourceDB, query, -1, &statement, nil) == SQLITE_OK else {
            throw MigrationError.cannotInspectLegacyStore
        }
        let hasClipboardTable = sqlite3_step(statement) == SQLITE_ROW
        sqlite3_finalize(statement)
        guard hasClipboardTable else { return }

        let sourceCount = try clipboardItemCount(in: source)
        if destinationExists && sourceCount == 0 {
            defaults.set(version, forKey: clipboardVersionKey)
            return
        }

        let stagedURL = destination.deletingLastPathComponent()
            .appendingPathComponent("clipboard-migration-\(UUID().uuidString).store")
        var destinationDB: OpaquePointer?
        defer {
            if let destinationDB { sqlite3_close(destinationDB) }
            if fileManager.fileExists(atPath: stagedURL.path) {
                do {
                    try fileManager.removeItem(at: stagedURL)
                } catch {
                    logger.error("Could not remove staged clipboard migration: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        guard sqlite3_open(stagedURL.path, &destinationDB) == SQLITE_OK,
              let openedDestinationDB = destinationDB,
              let backup = sqlite3_backup_init(openedDestinationDB, "main", sourceDB, "main") else {
            throw MigrationError.cannotCreateNewStore
        }
        var result = sqlite3_backup_step(backup, -1)
        var retries = 0
        while (result == SQLITE_BUSY || result == SQLITE_LOCKED), retries < 20 {
            sqlite3_sleep(50)
            result = sqlite3_backup_step(backup, -1)
            retries += 1
        }
        sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE else {
            self.logger.error("Clipboard migration failed: SQLite code \(result)")
            throw MigrationError.backupFailed(result)
        }
        sqlite3_close(openedDestinationDB)
        destinationDB = nil
        guard try clipboardItemCount(in: stagedURL) == sourceCount else {
            throw MigrationError.copyVerificationFailed
        }

        if destinationExists {
            let recoveryDirectory = destination.deletingLastPathComponent()
                .appendingPathComponent("pre-migration-backup-\(UUID().uuidString)")
            try fileManager.createDirectory(at: recoveryDirectory, withIntermediateDirectories: false)
            var movedFiles: [(original: URL, backup: URL)] = []
            do {
                for suffix in ["", "-wal", "-shm"] {
                    let original = URL(fileURLWithPath: destination.path + suffix)
                    if fileManager.fileExists(atPath: original.path) {
                        let backup = recoveryDirectory.appendingPathComponent(original.lastPathComponent)
                        try fileManager.moveItem(at: original, to: backup)
                        movedFiles.append((original, backup))
                    }
                }
                try fileManager.moveItem(at: stagedURL, to: destination)
            } catch {
                for pair in movedFiles.reversed() {
                    do {
                        try fileManager.moveItem(at: pair.backup, to: pair.original)
                    } catch {
                        logger.error("Could not restore clipboard store after migration error: \(error.localizedDescription, privacy: .public)")
                    }
                }
                throw error
            }
        } else {
            try fileManager.moveItem(at: stagedURL, to: destination)
        }
        defaults.set(version, forKey: clipboardVersionKey)
        logger.info("Clipboard store migrated")
    }

    private static func clipboardItemCount(in url: URL) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else { throw MigrationError.cannotInspectLegacyStore }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM ZCLIPBOARDITEMENTITY", -1, &statement, nil) == SQLITE_OK else {
            throw MigrationError.cannotInspectLegacyStore
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw MigrationError.cannotInspectLegacyStore }
        return Int(sqlite3_column_int64(statement, 0))
    }

    enum MigrationError: LocalizedError {
        case cannotOpenLegacyStore
        case cannotInspectLegacyStore
        case cannotCreateNewStore
        case backupFailed(Int32)
        case copyVerificationFailed

        var errorDescription: String? {
            switch self {
            case .cannotOpenLegacyStore: "Cannot open previous clipboard store"
            case .cannotInspectLegacyStore: "Cannot inspect previous clipboard store"
            case .cannotCreateNewStore: "Cannot create new clipboard store"
            case .backupFailed(let code): "Clipboard migration failed with SQLite code \(code)"
            case .copyVerificationFailed: "Clipboard migration copy could not be verified"
            }
        }
    }
}
