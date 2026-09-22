import AppKit
import SwiftData
import XCTest
@testable import Orvia

@MainActor
final class ClipboardReliabilityTests: XCTestCase {
    private func makeServices() throws -> (AppSettings, ClipboardStorageService, NSPasteboard, ClipboardMonitorService) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OrviaTests.\(UUID().uuidString)"))
        let settings = AppSettings(userDefaults: defaults)
        let container = try ModelContainer(
            for: ClipboardItemEntity.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let storage = ClipboardStorageService(
            modelContext: ModelContext(container),
            settings: settings,
            cryptoService: LocalCryptoService()
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OrviaTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        let monitor = ClipboardMonitorService(
            pasteboard: pasteboard, storageService: storage, settings: settings,
            sourceBundleIDProvider: { "com.example.external" }
        )
        return (settings, storage, pasteboard, monitor)
    }

    func testOwnWriteSuppressesOnlyMatchingChangeCount() throws {
        let (_, storage, pasteboard, monitor) = try makeServices()
        pasteboard.setString("own write", forType: .string)
        NotificationCenter.default.post(name: .clipboardDidProgrammaticWrite, object: nil)
        monitor.pollPasteboard()
        XCTAssertTrue(storage.fetchItems().isEmpty)

        pasteboard.clearContents()
        pasteboard.setString("external write", forType: .string)
        monitor.pollPasteboard()
        XCTAssertEqual(storage.fetchItems().count, 1)
    }

    func testPauseDiscardsChangesInsteadOfCapturingOnResume() throws {
        let (settings, storage, pasteboard, monitor) = try makeServices()
        settings.pauseMonitoring = true
        pasteboard.setString("private while paused", forType: .string)
        monitor.pollPasteboard()
        settings.pauseMonitoring = false
        monitor.pollPasteboard()
        XCTAssertTrue(storage.fetchItems().isEmpty)
    }

    func testConcealedPasteboardItemIsNeverSaved() throws {
        let (_, storage, pasteboard, monitor) = try makeServices()
        let item = NSPasteboardItem()
        item.setString("secret", forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.writeObjects([item])
        monitor.pollPasteboard()
        XCTAssertTrue(storage.fetchItems().isEmpty)
    }

    func testDuplicateRefreshesRecencyAndPreservesPin() throws {
        let (_, storage, _, _) = try makeServices()
        let data = Data("same".utf8)
        let hash = ClipboardContentClassifier.sha256Hex(data)
        let first = Date().addingTimeInterval(-60)
        storage.insert(
            snapshot: ClipboardSnapshot(kind: .text, textSubtype: .plain, payload: data, contentHash: hash, createdAt: first),
            sourceBundleID: "com.example.first"
        )
        let item = try XCTUnwrap(storage.fetchItems().first)
        storage.togglePin(itemID: item.id)
        let recent = Date()
        storage.insert(
            snapshot: ClipboardSnapshot(kind: .text, textSubtype: .plain, payload: data, contentHash: hash, createdAt: recent),
            sourceBundleID: "com.example.second"
        )
        let items = storage.fetchItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(try XCTUnwrap(items.first).isPinned)
        XCTAssertEqual(items.first?.createdAt, recent)
        XCTAssertEqual(items.first?.sourceBundleID, "com.example.second")
    }

    func testWakeRestartsStoppedMonitor() throws {
        let (_, _, _, monitor) = try makeServices()
        monitor.start()
        XCTAssertTrue(monitor.isRunning)
        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
        monitor.handleWake()
        XCTAssertTrue(monitor.isRunning)
        monitor.stop()
    }

    func testExpirationPreservesPinnedItem() throws {
        let (settings, storage, _, _) = try makeServices()
        settings.historyRetentionDays = 0
        let oldDate = Date().addingTimeInterval(-10 * 86_400)
        for (text, date) in [("keep", oldDate), ("expire", oldDate.addingTimeInterval(1))] {
            let data = Data(text.utf8)
            storage.insert(
                snapshot: ClipboardSnapshot(
                    kind: .text, textSubtype: .plain, payload: data,
                    contentHash: ClipboardContentClassifier.sha256Hex(data), createdAt: date
                ),
                sourceBundleID: nil
            )
        }
        let pinned = try XCTUnwrap(storage.fetchItems().first { storage.decode($0)?.text == "keep" })
        storage.togglePin(itemID: pinned.id)
        settings.historyRetentionDays = 7
        let remaining = storage.fetchItems()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(storage.decode(try XCTUnwrap(remaining.first))?.text, "keep")
    }

    func testRecentItemDoesNotExpire() throws {
        let (settings, storage, _, _) = try makeServices()
        settings.historyRetentionDays = 30
        let data = Data("recent".utf8)
        storage.insert(snapshot: ClipboardSnapshot(
            kind: .text, textSubtype: .plain, payload: data,
            contentHash: ClipboardContentClassifier.sha256Hex(data), createdAt: Date()
        ), sourceBundleID: nil)
        XCTAssertEqual(storage.fetchItems().count, 1)
    }
}
