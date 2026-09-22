import Foundation
import SQLite3
import SwiftData
import XCTest
@testable import Orvia

final class LegacyMigrationTests: XCTestCase {
    func testPreferenceMigrationIsIdempotentAndPreservesNewValues() throws {
        let previous = try XCTUnwrap(UserDefaults(suiteName: "OrviaTests.old.\(UUID().uuidString)"))
        let current = try XCTUnwrap(UserDefaults(suiteName: "OrviaTests.new.\(UUID().uuidString)"))
        previous.set(250, forKey: "historyLimit")
        previous.set(["com.example.private"], forKey: "ignoredBundleIDs")
        current.set(500, forKey: "historyLimit")

        LegacyMigration.migratePreferences(to: current, from: previous)
        XCTAssertEqual(current.integer(forKey: "historyLimit"), 500)
        XCTAssertEqual(current.stringArray(forKey: "ignoredBundleIDs"), ["com.example.private"])
        previous.set(["com.example.changed"], forKey: "ignoredBundleIDs")
        LegacyMigration.migratePreferences(to: current, from: previous)
        XCTAssertEqual(current.stringArray(forKey: "ignoredBundleIDs"), ["com.example.private"])
    }

    func testClipboardBackupCopiesStoreOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrviaMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("default.store")
        let destination = directory.appendingPathComponent("Orvia/clipboard.store")
        let suiteName = "OrviaTests.backup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(
            database,
            "CREATE TABLE ZCLIPBOARDITEMENTITY (VALUE TEXT); INSERT INTO ZCLIPBOARDITEMENTITY VALUES ('history')",
            nil, nil, nil
        ), SQLITE_OK)
        sqlite3_close(database)

        try LegacyMigration.migrateClipboardStore(to: destination, from: source, defaults: defaults)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let initialSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)
        try LegacyMigration.migrateClipboardStore(to: destination, from: source, defaults: defaults)
        let finalSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)
        XCTAssertEqual(initialSize, finalSize)
    }

    func testEmptyNewStoreRecoversOldHistoryOnlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrviaMigrationRecovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("default.store")
        let destination = directory.appendingPathComponent("Orvia/clipboard.store")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let suiteName = "OrviaTests.recovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for url in [source, destination] {
            var database: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE ZCLIPBOARDITEMENTITY (VALUE TEXT)", nil, nil, nil), SQLITE_OK)
            if url == source {
                XCTAssertEqual(sqlite3_exec(database, "INSERT INTO ZCLIPBOARDITEMENTITY VALUES ('history')", nil, nil, nil), SQLITE_OK)
            }
            sqlite3_close(database)
        }

        try LegacyMigration.migrateClipboardStore(to: destination, from: source, defaults: defaults)
        XCTAssertEqual(try clipboardCount(in: destination), 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
            .contains { $0.hasPrefix("pre-migration-backup-") })

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(destination.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "DELETE FROM ZCLIPBOARDITEMENTITY", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        try LegacyMigration.migrateClipboardStore(to: destination, from: source, defaults: defaults)
        XCTAssertEqual(try clipboardCount(in: destination), 0)
    }

    private func clipboardCount(in url: URL) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { throw NSError(domain: "SQLite", code: 1) }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM ZCLIPBOARDITEMENTITY", -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLite", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw NSError(domain: "SQLite", code: 3) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    @MainActor
    func testMigratedStoreSurvivesModelOpen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrviaModelMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail(error.localizedDescription) }
        }
        let source = directory.appendingPathComponent("default.store")
        let sourceContainer = try ModelContainer(
            for: ClipboardItemEntity.self,
            configurations: ModelConfiguration(url: source)
        )
        let sourceContext = ModelContext(sourceContainer)
        sourceContext.insert(ClipboardItemEntity(
            createdAt: Date(), updatedAt: Date(), kindRaw: ClipboardContentKind.text.rawValue,
            textSubtypeRaw: ClipboardTextSubtype.plain.rawValue, payload: Data("history".utf8),
            isEncrypted: false, contentHash: "fixture", sourceBundleID: nil, isPinned: true
        ))
        try sourceContext.save()
        let destination = directory.appendingPathComponent("Orvia/clipboard.store")
        let suiteName = "OrviaTests.live.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try LegacyMigration.migrateClipboardStore(to: destination, from: source, defaults: defaults)
        let container = try ModelContainer(
            for: ClipboardItemEntity.self,
            configurations: ModelConfiguration(url: destination)
        )
        let context = ModelContext(container)
        let countBeforeFetch = try context.fetchCount(FetchDescriptor<ClipboardItemEntity>())
        XCTAssertGreaterThan(countBeforeFetch, 0)
        let settings = AppSettings(userDefaults: defaults)
        let storage = ClipboardStorageService(
            modelContext: context, settings: settings,
            cryptoService: LocalCryptoService()
        )
        XCTAssertEqual(storage.fetchItems().count, countBeforeFetch)
        XCTAssertTrue(try XCTUnwrap(storage.fetchItems().first).isPinned)
    }
}
