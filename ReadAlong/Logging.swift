import Foundation
import os

enum Log {
    static let server = Logger(subsystem: "com.sharathkrml.readalong", category: "server")

    @MainActor
    static func note(_ message: String) {
        Logger(subsystem: "com.sharathkrml.readalong", category: "app").notice("\(message)")

        let formatter = ISO8601DateFormatter()
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ReadAlong.log")
        let data = Data("\(formatter.string(from: Date())) \(message)\n".utf8)
        let manager = FileManager.default

        if !manager.fileExists(atPath: fileURL.path) {
            manager.createFile(atPath: fileURL.path, contents: data)
            return
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
