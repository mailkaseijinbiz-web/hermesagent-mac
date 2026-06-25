import Foundation
import os

/// Categorized structured logging (replaces scattered `print`). View in Console.app
/// or `log stream --predicate 'subsystem == "com.custom.hermesmac"'`.
enum Log {
    private static let subsystem = "com.custom.hermesmac"

    static let acp = Logger(subsystem: subsystem, category: "acp")
    static let server = Logger(subsystem: subsystem, category: "server")
    static let push = Logger(subsystem: subsystem, category: "push")
    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let app = Logger(subsystem: subsystem, category: "app")
}
