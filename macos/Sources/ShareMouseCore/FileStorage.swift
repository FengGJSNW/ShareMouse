import CryptoKit
import Darwin
import Foundation

public enum FileStorage {
    public static func isTransferMetadata(_ name: String) -> Bool {
        if name == ".DS_Store" { return true }
        return name.hasPrefix(".ShareMouse-") && UUID(uuidString: String(name.dropFirst(".ShareMouse-".count))) != nil
            || name.hasPrefix(".ShareMouse.") && name.count > ".ShareMouse.".count
    }
    public static func inspect(_ path: String, template: FileItem) throws -> LocalFile {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let type = attributes[.type] as? FileAttributeType,
            type == .typeRegular || type == .typeDirectory || type == .typeSymbolicLink
        else { throw FileTransferError.invalidPath }
        var item = template;
        item.directory = type == .typeDirectory
        item.linkTarget =
            type == .typeSymbolicLink ? try FileManager.default.destinationOfSymbolicLink(atPath: path) : nil
        var linkDirectory: ObjCBool = false
        item.linkDirectory =
            type == .typeSymbolicLink
            ? (FileManager.default.fileExists(atPath: path, isDirectory: &linkDirectory) && linkDirectory.boolValue)
            : nil
        item.size = item.directory || item.linkTarget != nil ? 0 : (attributes[.size] as? NSNumber)?.int64Value ?? 0
        item.modified = Int64(((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000)
        var identity =
            "\((attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0):\((attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)"
        if !item.directory, let modified = attributes[.modificationDate] as? Date {
            identity += ":" + String(modified.timeIntervalSince1970.bitPattern)
        }
        return LocalFile(item: item, path: path, identity: identity)
    }
    public static func same(_ a: LocalFile, _ b: LocalFile) -> Bool {
        a.identity == b.identity && a.item.size == b.item.size && a.item.modified == b.item.modified
            && a.item.directory == b.item.directory && a.item.linkTarget == b.item.linkTarget
            && a.item.linkDirectory == b.item.linkDirectory
    }
    public static func unchanged(_ file: LocalFile) -> Bool {
        guard let actual = try? inspect(file.path, template: file.item) else { return false };
        return same(file, actual)
    }
    public static func scan(_ paths: [String], previous: FileTransaction? = nil) async throws -> (
        [LocalRoot], [LocalFile]
    ) {
        try await Task.detached {
            var roots: [LocalRoot] = [];
            var files: [LocalFile] = [];
            var names: Set<String> = []
            let previousFiles = Dictionary(
                uniqueKeysWithValues: (previous?.files ?? []).map { ($0.item.rootID + ":" + $0.item.relativePath, $0) })
            func walk(_ path: String, _ relative: String, _ rootID: String, _ top: Bool) throws {
                guard relative.utf8.count <= 1024 else { throw FileTransferError.invalidPath }
                guard files.count < 100000 else { throw FileTransferError.invalidDataSize }
                let old = previousFiles[rootID + ":" + relative]
                let item = FileItem(
                    id: old?.item.id ?? (top ? rootID : UUID().uuidString.lowercased()), rootID: rootID,
                    relativePath: relative, directory: false, size: 0, modified: 0)
                var current = try inspect(path, template: item)
                if let link = current.item.linkTarget {
                    guard !top, validLink(relative: relative, target: link),
                        let root = roots.first(where: { $0.id == rootID })
                    else { throw FileTransferError.invalidPath }
                    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
                    guard resolved == root.path || resolved.hasPrefix(root.path + "/") else {
                        throw FileTransferError.invalidPath
                    }
                }
                if let old, same(old, current) { current.item.hash = old.item.hash };
                files.append(current)
                if current.item.directory {
                    for child in try FileManager.default.contentsOfDirectory(atPath: path).sorted()
                    where !isTransferMetadata(child) {
                        try walk(path + "/" + child, relative + "/" + child, rootID, false)
                    }
                }
            }
            for selected in Set(paths).sorted() {
                let url = URL(fileURLWithPath: selected).standardizedFileURL
                // Reject a selected symlink before resolving its parent path.
                guard
                    try inspect(
                        url.path,
                        template: FileItem(id: "", rootID: "", relativePath: "", directory: false, size: 0, modified: 0)
                    ).item.linkTarget == nil
                else { throw FileTransferError.invalidPath }
                let path = url.resolvingSymlinksInPath().path;
                let original = url.lastPathComponent
                guard !original.isEmpty, path != "/" else { throw FileTransferError.invalidPath }
                let root =
                    previous?.roots.first { $0.path == path }
                    ?? LocalRoot(id: UUID().uuidString.lowercased(), path: path)
                let displayName = previous?.files.first { $0.item.id == root.id }?.item.relativePath ?? original
                var name = displayName;
                var suffix = 2
                while !names.insert(name).inserted {
                    name = displayName + " (\(suffix))";
                    suffix += 1
                }
                roots.append(root);
                try walk(path, name, root.id, true)
            }
            return (roots, files)
        }.value
    }
    public static func validLink(relative: String, target: String) -> Bool {
        guard !target.isEmpty, target.utf8.count <= 1024, !target.hasPrefix("/"), !target.contains("\\"),
            !target.contains(":"), !target.contains("\0")
        else { return false }
        var parts = relative.split(separator: "/").dropLast().map(String.init)
        guard !parts.isEmpty else { return false }
        for part in target.split(separator: "/") {
            if part == ".." {
                if parts.count <= 1 { return false };
                parts.removeLast()
            } else if part != "." {
                parts.append(String(part))
            }
        }
        return true
    }
    public static func finishLink(_ file: TransferFile, destination: String, root: String) throws {
        guard let link = file.item.linkTarget, validLink(relative: file.item.relativePath, target: link) else {
            throw FileTransferError.invalidPath
        }
        try ensureParent(destination, target: file.target)
        let resolved = URL(fileURLWithPath: file.target).deletingLastPathComponent().appendingPathComponent(link)
            .standardizedFileURL
        guard resolved.path == root || resolved.path.hasPrefix(root + "/") else { throw FileTransferError.invalidPath }
        let canonical = resolved.resolvingSymlinksInPath().path
        guard canonical == root || canonical.hasPrefix(root + "/") else { throw FileTransferError.invalidPath }
        if (try? FileManager.default.attributesOfItem(atPath: file.target)) != nil {
            try FileManager.default.removeItem(atPath: file.target)
        }
        try FileManager.default.createSymbolicLink(atPath: file.target, withDestinationPath: link)
        file.completedIdentity = try inspect(file.target, template: file.item).identity
    }
    public static func additions(indexed: [LocalFile], scanned: [LocalFile]) -> [LocalFile] {
        let known = Set(indexed.map { $0.item.rootID + ":" + $0.item.relativePath })
        return scanned.filter { !known.contains($0.item.rootID + ":" + $0.item.relativePath) }
    }
    public static func hash(_ path: String) async throws -> String {
        try await Task.detached {
            let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: path));
            defer { try? input.close() }
            var hash = SHA256()
            while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
    public static func target(_ destination: String, relative: String) throws -> String {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty,
            parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") })
        else { throw FileTransferError.invalidPath }
        let root = URL(fileURLWithPath: destination).standardizedFileURL.path
        let path = URL(fileURLWithPath: root).appendingPathComponent(relative).standardizedFileURL.path
        guard path.hasPrefix(root == "/" ? "/" : root + "/") else { throw FileTransferError.invalidPath };
        return path
    }
    public static func ensureParent(_ destination: String, target: String) throws {
        let root = URL(fileURLWithPath: destination).standardizedFileURL.path
        let parent = URL(fileURLWithPath: target).deletingLastPathComponent().path
        guard parent == root || parent.hasPrefix(root + "/") else { throw FileTransferError.invalidPath }
        var current = root
        for part in parent.dropFirst(root.count).split(separator: "/") {
            current += "/" + part
            if FileManager.default.fileExists(atPath: current) {
                let attributes = try FileManager.default.attributesOfItem(atPath: current)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw FileTransferError.invalidPath
                }
            } else {
                try FileManager.default.createDirectory(atPath: current, withIntermediateDirectories: false)
            }
        }
    }
    public static func partial(_ destination: String, taskID: String, itemID: String) throws -> String {
        guard UUID(uuidString: taskID) != nil, UUID(uuidString: itemID) != nil else {
            throw FileTransferError.invalidPath
        }
        let directory = try target(destination, relative: ".ShareMouse-" + taskID)
        try ensureParent(destination, target: directory + "/" + itemID)
        return directory + "/" + itemID + ".partial"
    }
    public static func append(_ file: TransferFile, data: Data) async throws {
        let partial = file.partial;
        let received = file.received
        try await Task.detached {
            if !FileManager.default.fileExists(atPath: partial) {
                guard FileManager.default.createFile(atPath: partial, contents: nil) else {
                    throw FileTransferError.unavailable
                }
            }
            let output = try FileHandle(forWritingTo: URL(fileURLWithPath: partial));
            defer { try? output.close() }
            guard try output.seekToEnd() >= UInt64(received) else { throw FileTransferError.corrupt }
            try output.truncate(atOffset: UInt64(received));
            try output.seek(toOffset: UInt64(received));
            try output.write(contentsOf: data);
            try output.synchronize()
        }.value
    }
    public static func finish(_ file: TransferFile, destination: String) throws {
        try ensureParent(destination, target: file.target)
        guard rename(file.partial, file.target) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: Double(file.item.modified) / 1000)],
            ofItemAtPath: file.target)
        file.completedIdentity = try inspect(file.target, template: file.item).identity
        let staging = URL(fileURLWithPath: file.partial).deletingLastPathComponent().path
        // Remove only empty staging directories; resumable entries remain.
        if isTransferMetadata(URL(fileURLWithPath: staging).lastPathComponent) { _ = rmdir(staging) }
    }
    public static func completedUnchanged(_ file: TransferFile) -> Bool {
        guard let actual = try? inspect(file.target, template: file.item) else { return false };
        return actual.identity == file.completedIdentity && actual.item.size == file.item.size
            && actual.item.directory == file.item.directory && actual.item.linkTarget == file.item.linkTarget
    }
    public static func read(_ file: LocalFile, offset: Int64, maximum: Int = 20000) async throws -> Data {
        try await Task.detached {
            guard offset >= 0, offset <= file.item.size, unchanged(file) else { throw FileTransferError.changed }
            let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: file.path));
            defer { try? input.close() }
            try input.seek(toOffset: UInt64(offset));
            let count = Int(min(Int64(max(1, min(32000, maximum))), file.item.size - offset))
            let bytes = try input.read(upToCount: count) ?? Data();
            guard bytes.count == count else { throw FileTransferError.changed };
            return bytes
        }.value
    }
    public static func deleteVerifiedRoot(_ snapshot: FileTransaction, rootID: String) async throws {
        guard let root = snapshot.roots.first(where: { $0.id == rootID }) else { throw FileTransferError.invalidPath }
        let expected = snapshot.files.filter { $0.item.rootID == rootID }
        let (_, actual) = try await scan([root.path], previous: snapshot)
        guard actual.count <= expected.count,
            actual.allSatisfy({ file in
                expected.contains {
                    $0.item.relativePath == file.item.relativePath
                        && ($0.item.directory ? file.item.directory && $0.identity == file.identity : same(file, $0))
                }
            })
        else { throw FileTransferError.changed }
        for file in expected.filter({ FileManager.default.fileExists(atPath: $0.path) }).sorted(by: {
            $0.item.relativePath.filter { $0 == "/" }.count > $1.item.relativePath.filter { $0 == "/" }.count
        }) {
            try Task.checkCancellation()
            if file.item.directory {
                let actual = try inspect(file.path, template: file.item)
                guard actual.identity == file.identity, actual.item.directory else { throw FileTransferError.changed }
                let metadata = file.path + "/.DS_Store"
                if FileManager.default.fileExists(atPath: metadata) {
                    let item = try inspect(metadata, template: file.item)
                    guard !item.item.directory else { throw FileTransferError.changed };
                    try FileManager.default.removeItem(atPath: metadata)
                }
                guard rmdir(file.path) == 0 else { throw FileTransferError.changed }
            } else {
                guard unchanged(file) else { throw FileTransferError.changed };
                try FileManager.default.removeItem(atPath: file.path)
            }
        }
    }
    public static func deleteAll(_ transaction: FileTransaction) throws {
        for root in transaction.roots where FileManager.default.fileExists(atPath: root.path) {
            guard let expected = transaction.files.first(where: { $0.item.id == root.id }) else {
                throw FileTransferError.invalidPath
            }
            let actual = try inspect(root.path, template: expected.item)
            func node(_ file: LocalFile) -> String {
                file.item.directory
                    ? file.identity : String(file.identity.prefix(upTo: file.identity.lastIndex(of: ":")!))
            }
            guard actual.item.directory == expected.item.directory, node(actual) == node(expected) else {
                throw FileTransferError.changed
            }
        }
        for root in transaction.roots where FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(atPath: root.path)
        }
    }
}
