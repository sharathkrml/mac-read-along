import Foundation
import os

enum Log {
    static let server = Logger(subsystem: "com.sharathkrml.readalong", category: "server")

    @MainActor
    static func note(_ message: String) {
        Logger(subsystem: "com.sharathkrml.readalong", category: "app").notice("\(message)")
    }
}
