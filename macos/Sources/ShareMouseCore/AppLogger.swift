import Foundation

public enum LogLevel: String {
    case trace = "TRACE", debug = "DEBUG", info = "INFO", warn = "WARN", error = "ERROR"
}

// Only lifecycle metadata belongs here. Never pass passwords, keys or clipboard/file content.
public final class AppLogger {
    private let handle: FileHandle
    private let formatter = ISO8601DateFormatter()

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("app.log")
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
    }

    public func write(_ level: LogLevel, _ event: String) throws {
        let line = "\(formatter.string(from: Date())) \(level.rawValue) \(event)\n"
        try handle.write(contentsOf: Data(line.utf8))
    }

    deinit { try? handle.close() }
}
