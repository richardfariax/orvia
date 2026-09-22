import Foundation
import XCTest
@testable import Orvia

final class CleanerSafetyTests: XCTestCase {
    func testSystemAndApplicationDataAreProtected() {
        XCTAssertTrue(FileSweeper.isProtected(URL(fileURLWithPath: "/")))
        XCTAssertTrue(FileSweeper.isProtected(URL(fileURLWithPath: "/System/Library")))
        XCTAssertTrue(FileSweeper.isProtected(FileManager.default.homeDirectoryForCurrentUser))
        let appData = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Orvia/clipboard.store")
        XCTAssertTrue(FileSweeper.isProtected(appData))
    }

    func testSymlinkCannotBeScannedOrRemovedAsCleanupItem() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrviaCleanerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail(error.localizedDescription) }
        }
        let target = directory.appendingPathComponent("target.txt")
        let link = directory.appendingPathComponent("link.txt")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertTrue(FileSweeper.isProtected(link))
        let result = FileSweeper.removePermanently(urls: [link])
        XCTAssertEqual(result.reclaimed, 0)
        XCTAssertFalse(result.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testDeletionMeasuresOnlySuccessfulFixtureRemoval() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrviaCleanerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail(error.localizedDescription) }
        }
        let item = directory.appendingPathComponent("cache.bin")
        try Data(repeating: 0x41, count: 4096).write(to: item)
        let result = FileSweeper.removePermanently(urls: [item])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertGreaterThan(result.reclaimed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.path))
    }

}
