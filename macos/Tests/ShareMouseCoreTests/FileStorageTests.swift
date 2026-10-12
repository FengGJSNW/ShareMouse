import Foundation
import XCTest
@testable import ShareMouseCore
final class FileStorageTests: XCTestCase {
    func testDirectoryTransferOmitsMetadataAndCleansOnlyEmptyStaging() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in [".DS_Store", ".ShareMouse.xxxxxx", ".keep-user-file", "中文.txt"] { try Data(name.utf8).write(to: source.appendingPathComponent(name)) }
        let stage = source.appendingPathComponent(".ShareMouse-" + UUID().uuidString.lowercased()); try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let (_, entries) = try await FileStorage.scan([source.path])
        XCTAssertEqual(Set(entries.map { URL(fileURLWithPath: $0.path).lastPathComponent }), ["source", ".keep-user-file", "中文.txt"])
        let item = FileItem(id: UUID().uuidString.lowercased(), rootID: UUID().uuidString.lowercased(), relativePath: "中文.txt", directory: false, size: 4, modified: 0)
        let partial = try FileStorage.partial(destination.path, taskID: UUID().uuidString.lowercased(), itemID: item.id)
        let target = try FileStorage.target(destination.path, relative: item.relativePath)
        let file = TransferFile(item: item, provider: "fixture", target: target, partial: partial)
        try Data("data".utf8).write(to: URL(fileURLWithPath: partial)); try FileStorage.finish(file, destination: destination.path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: target)), Data("data".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: partial).deletingLastPathComponent().path))
    }
    func testCutKeepsChangedSourceAndDeletesVerifiedDirectory() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("selected"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("Finder metadata".utf8).write(to: source.appendingPathComponent(".DS_Store"))
        let original = source.appendingPathComponent("中文.txt"); try Data("original ✓".utf8).write(to: original)
        let (roots, files) = try await FileStorage.scan([source.path])
        let entry = ClipboardEntry(id: UUID().uuidString.lowercased(), sourcePeerID: UUID().uuidString.lowercased(), counter: 1, timestamp: 1, kind: "files", byteCount: 0)
        let snapshot = FileTransaction(entry: entry, groupID: UUID().uuidString, roots: roots, files: files, originalCut: true)
        try Data("changed source".utf8).write(to: original)
        do { try await FileStorage.deleteVerifiedRoot(snapshot, rootID: roots[0].id); XCTFail("Changed Cut source deleted") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        let (newRoots, current) = try await FileStorage.scan([source.path], previous: snapshot)
        XCTAssertEqual(current.first { !$0.item.directory }?.item.id, files.first { !$0.item.directory }?.item.id)
        let hash = try await FileStorage.hash(original.path)
        XCTAssertEqual(hash, "0b07de62d81d8cd6203eaf31acb4f06429f057b59e9c2f88eae2ff59a47b250d")
        try await FileStorage.deleteVerifiedRoot(FileTransaction(entry: entry, groupID: snapshot.groupID, roots: newRoots, files: current, originalCut: true), rootID: roots[0].id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }
}
extension FileStorageTests {
    func testRelativeLinksPreservedAndOutsideLinksRejected() async throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:base)}
        let source=base.appendingPathComponent("folder"),destination=base.appendingPathComponent("received/folder")
        try FileManager.default.createDirectory(at:source.appendingPathComponent("deps/package"),withIntermediateDirectories:true)
        try Data("dependency".utf8).write(to:source.appendingPathComponent("deps/package/a.txt"))
        try FileManager.default.createSymbolicLink(atPath:source.appendingPathComponent("deps/link").path,withDestinationPath:"package")
        let (_,entries)=try await FileStorage.scan([source.path]);XCTAssertEqual(entries.count,5)
        let link=try XCTUnwrap(entries.first{$0.item.linkTarget != nil})
        XCTAssertEqual(link.item.linkTarget,"package");XCTAssertEqual(link.item.linkDirectory,true);XCTAssertEqual(link.item.size,0)
        try FileManager.default.createDirectory(at:destination.appendingPathComponent("deps/package"),withIntermediateDirectories:true)
        let transfer=TransferFile(item:link.item,provider:"test",target:destination.appendingPathComponent("deps/link").path,partial:"")
        try FileStorage.finishLink(transfer,destination:base.appendingPathComponent("received").path,root:destination.path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath:transfer.target),"package")
        XCTAssertTrue(FileStorage.completedUnchanged(transfer))
        XCTAssertTrue(FileStorage.validLink(relative:"folder/deps/link",target:"../deps/package"))
        XCTAssertFalse(FileStorage.validLink(relative:"folder/deps/link",target:"../../outside"))
        try FileManager.default.createSymbolicLink(atPath:source.appendingPathComponent("bad").path,withDestinationPath:"../outside")
        do{_ = try await FileStorage.scan([source.path]);XCTFail("Outside link was accepted")}catch{XCTAssertEqual(error as? FileTransferError,.invalidPath)}
    }
    func testUserFolderCatalogueWhenRequested() async throws {
        guard let path=ProcessInfo.processInfo.environment["SHAREMOUSE_TEST_FOLDER"] else{return}
        let (_,entries)=try await FileStorage.scan([path]);XCTAssertFalse(entries.isEmpty)
        print("USER_FOLDER_CATALOGUE entries=\(entries.count) links=\(entries.filter{$0.item.linkTarget != nil}.count) bytes=\(entries.reduce(0){$0+$1.item.size})")
    }
}
