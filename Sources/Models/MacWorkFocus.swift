import Foundation

/// Mac 作業ログから「何をしていたか」を取り出す（ツール名は副情報）。
enum MacWorkFocus {
    private static let browserApps: Set<String> = [
        "Safari", "Google Chrome", "Chrome", "Arc", "Firefox",
        "Microsoft Edge", "Brave Browser", "Orion",
    ]

    private static let browserSuffixes = [
        " - Google Chrome", " - Mozilla Firefox", " — Safari", " - Safari",
        " - Arc", " - Microsoft Edge", " — Google Chrome", " — Arc",
        " - Brave", " — Firefox",
    ]

    static func workTitle(for entry: MacActivityEntry) -> String {
        if entry.kind == "hermes" {
            let title = entry.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? "Hermes チャット" : title
        }

        if let page = browserWorkTitle(entry) { return page }

        let document = resolvedWindowTitle(entry)
        if !document.isEmpty { return document }

        let app = entry.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        return app.isEmpty ? "Mac作業" : app
    }

    static func toolName(for entry: MacActivityEntry) -> String {
        if entry.kind == "hermes" { return "Hermes" }
        return entry.appName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func subtitle(for entry: MacActivityEntry) -> String? {
        let work = workTitle(for: entry)
        let tool = toolName(for: entry)
        guard entry.kind != "hermes", !tool.isEmpty, work != tool else { return nil }
        return tool
    }

    static func focusGroupKey(for entry: MacActivityEntry) -> String {
        "\(entry.kind)|\(workTitle(for: entry).lowercased())"
    }

    // MARK: - Private

    private static func browserWorkTitle(_ entry: MacActivityEntry) -> String? {
        guard entry.url != nil || isBrowser(entry.appName) else { return nil }
        let window = resolvedWindowTitle(entry)
        if !window.isEmpty { return window }
        if let url = entry.url?.trimmingCharacters(in: .whitespacesAndNewlines),
           !url.isEmpty,
           let host = URL(string: url)?.host,
           !host.isEmpty {
            return host
        }
        return nil
    }

    private static func isBrowser(_ appName: String) -> Bool {
        browserApps.contains(appName.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func resolvedWindowTitle(_ entry: MacActivityEntry) -> String {
        if let wt = entry.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !wt.isEmpty {
            return cleanWindowTitle(wt, appName: entry.appName)
        }
        let label = entry.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = entry.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label != app else { return "" }
        if label.hasPrefix("\(app) — ") {
            return cleanWindowTitle(String(label.dropFirst(app.count + 3)), appName: app)
        }
        if label.hasSuffix(" — \(app)") {
            return cleanWindowTitle(String(label.dropLast(app.count + 3)), appName: app)
        }
        return cleanWindowTitle(label, appName: app)
    }

    private static func cleanWindowTitle(_ raw: String, appName: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return "" }

        for suffix in browserSuffixes where title.hasSuffix(suffix) {
            title = String(title.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let app = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !app.isEmpty {
            if title.hasSuffix(" — \(app)") {
                title = String(title.dropLast(app.count + 3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if title.hasPrefix("\(app) — ") {
                title = String(title.dropFirst(app.count + 3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let range = title.range(of: " — ", options: .backwards) {
            let suffix = String(title[range.upperBound...])
            if suffix == app || browserApps.contains(suffix) {
                title = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return title
    }
}
