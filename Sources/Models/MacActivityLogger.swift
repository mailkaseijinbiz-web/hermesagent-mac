import AppKit
import ApplicationServices
import Foundation

/// Mac で行っていることを記録するエントリ。
/// kind: "app" = 一般アプリセッション、"hermes" = Hermes チャットセッション
struct MacActivityEntry: Codable, Identifiable {
    var id: String           = UUID().uuidString
    var kind: String         = "app"        // "app" | "hermes"
    var appName: String      = ""           // アプリ名 or 社員名
    var bundleId: String?    = nil          // バンドルID（Optionalでバックコンパット）
    var label: String        = ""           // 表示ラベル
    var windowTitle: String? = nil          // ウィンドウタイトル（Optionalでバックコンパット）
    var url: String?         = nil          // ブラウザURL（Optionalでバックコンパット）
    var startTime: Double    = 0            // epoch seconds
    var endTime: Double      = 0            // epoch seconds
    var duration: Double     { endTime - startTime }
    var startDate: Date      { Date(timeIntervalSince1970: startTime) }
}

/// NSWorkspace のアプリ切り替えを監視し「アプリセッション」として記録する。
/// ブラウザ（Chrome等）では 8 秒ポーリングでタブ切り替えも検知し URL を記録する。
/// Hermes チャットも同じ JSON に混在させる（MobileServer が /api/mac-activity で配信）。
@MainActor
final class MacActivityLogger {
    static let shared = MacActivityLogger()

    private let minDuration: TimeInterval = 30
    private let browserBundles: Set<String> = [
        "com.google.Chrome",
        "org.mozilla.firefox",
        "com.apple.Safari",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac"
    ]

    private var completedEntries: [MacActivityEntry] = []
    private var currentApp:          String = ""
    private var currentBundle:       String = ""
    private var currentPID:          pid_t  = 0
    private var currentStart:        Date?  = nil
    private var currentWindowTitle:  String = ""
    private var currentURL:          String = ""
    private var pollTimer:           Timer? = nil

    private var cacheFilePath: String {
        "\(NSHomeDirectory())/.hermes/mac-activity-\(dayKey(Date())).json"
    }

    func start() {
        loadToday()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            Task { @MainActor in self?.onActivate(app) }
        }
        if let front = NSWorkspace.shared.frontmostApplication {
            onActivate(front)
        }
        // ブラウザのタブ切り替えを検知するためのポーリング（8秒ごと）
        pollTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollCurrentSession() }
        }
    }

    /// Hermes チャットが完了（返答が来た）したときに呼ぶ。
    func recordHermesSession(employeeName: String, sessionTitle: String,
                             start: Date, end: Date) {
        let dur = end.timeIntervalSince(start)
        guard dur >= minDuration else { return }
        var entry = MacActivityEntry()
        entry.kind      = "hermes"
        entry.appName   = employeeName
        entry.label     = sessionTitle.isEmpty ? "Hermes チャット" : sessionTitle
        entry.startTime = start.timeIntervalSince1970
        entry.endTime   = end.timeIntervalSince1970
        completedEntries.append(entry)
        completedEntries.sort { $0.startTime < $1.startTime }
        saveToday()
    }

    /// 今日の全エントリ（完了済み + 進行中）を配列として返す（ライフログ UI 用）。
    func todayEntries() -> [MacActivityEntry] {
        var all = completedEntries
        if let start = currentStart, !currentApp.isEmpty {
            let dur = Date().timeIntervalSince(start)
            if dur >= minDuration {
                var live = MacActivityEntry()
                live.appName      = currentApp
                live.bundleId     = currentBundle.isEmpty ? nil : currentBundle
                live.windowTitle  = currentWindowTitle.isEmpty ? nil : currentWindowTitle
                live.url          = currentURL.isEmpty ? nil : currentURL
                live.label        = Self.buildLabel(appName: currentApp, windowTitle: currentWindowTitle)
                live.startTime    = start.timeIntervalSince1970
                live.endTime      = Date().timeIntervalSince1970
                all.append(live)
            }
        }
        return all
    }

    /// 今日の全エントリ（完了済み + 進行中）を JSON データとして返す。
    func todayJSON() -> Data {
        var all = completedEntries
        if let start = currentStart, !currentApp.isEmpty {
            let dur = Date().timeIntervalSince(start)
            if dur >= minDuration {
                var live = MacActivityEntry()
                live.appName      = currentApp
                live.bundleId     = currentBundle.isEmpty ? nil : currentBundle
                live.windowTitle  = currentWindowTitle.isEmpty ? nil : currentWindowTitle
                live.url          = currentURL.isEmpty ? nil : currentURL
                live.label        = Self.buildLabel(appName: currentApp, windowTitle: currentWindowTitle)
                live.startTime    = start.timeIntervalSince1970
                live.endTime      = Date().timeIntervalSince1970
                all.append(live)
            }
        }
        return (try? JSONEncoder().encode(all)) ?? Data("[]".utf8)
    }

    // MARK: - アプリ切り替え

    private func onActivate(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular else { return }
        let bundle = app.bundleIdentifier ?? ""
        let name   = app.localizedName ?? bundle.components(separatedBy: ".").last ?? "不明"
        let pid    = app.processIdentifier

        // 前のセッションを閉じる
        if let start = currentStart, !currentApp.isEmpty {
            let dur = Date().timeIntervalSince(start)
            if dur >= minDuration {
                var entry = MacActivityEntry()
                entry.appName     = currentApp
                entry.bundleId    = currentBundle.isEmpty ? nil : currentBundle
                entry.windowTitle = currentWindowTitle.isEmpty ? nil : currentWindowTitle
                entry.url         = currentURL.isEmpty ? nil : currentURL
                entry.label       = Self.buildLabel(appName: currentApp, windowTitle: currentWindowTitle)
                entry.startTime   = start.timeIntervalSince1970
                entry.endTime     = Date().timeIntervalSince1970
                mergeOrAppend(entry)
                saveToday()
            }
        }

        currentApp         = name
        currentBundle      = bundle
        currentPID         = pid
        currentStart       = Date()
        currentWindowTitle = ""
        currentURL         = ""

        let isBrowser = browserBundles.contains(bundle)
        Task.detached { [weak self] in
            let (title, url) = MacActivityLogger.fetchWindowTitleAndURL(pid: pid, isBrowser: isBrowser)
            await MainActor.run {
                self?.currentWindowTitle = title
                self?.currentURL = url
            }
        }
    }

    // MARK: - ポーリング（ブラウザのタブ切り替え検知）

    private func pollCurrentSession() {
        guard currentStart != nil, !currentApp.isEmpty else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == currentPID else { return }
        let pid = currentPID
        let isBrowser = browserBundles.contains(currentBundle)
        Task.detached { [weak self] in
            let (title, url) = MacActivityLogger.fetchWindowTitleAndURL(pid: pid, isBrowser: isBrowser)
            await MainActor.run { [weak self] in self?.applyPollResult(title: title, url: url) }
        }
    }

    private func applyPollResult(title: String, url: String) {
        guard let start = currentStart, !currentApp.isEmpty else { return }
        let isBrowser = browserBundles.contains(currentBundle)

        // 変化の検出: ブラウザはURL、それ以外はタイトル
        let changed = isBrowser
            ? (!url.isEmpty && url != currentURL)
            : (!title.isEmpty && !currentWindowTitle.isEmpty && title != currentWindowTitle)

        guard changed else {
            if !title.isEmpty { currentWindowTitle = title }
            if !url.isEmpty   { currentURL = url }
            return
        }

        // タブ切り替え確定 → 現在サブセッションを記録
        let dur = Date().timeIntervalSince(start)
        if dur >= minDuration {
            var entry = MacActivityEntry()
            entry.appName     = currentApp
            entry.bundleId    = currentBundle.isEmpty ? nil : currentBundle
            entry.windowTitle = currentWindowTitle.isEmpty ? nil : currentWindowTitle
            entry.url         = currentURL.isEmpty ? nil : currentURL
            entry.label       = Self.buildLabel(appName: currentApp, windowTitle: currentWindowTitle)
            entry.startTime   = start.timeIntervalSince1970
            entry.endTime     = Date().timeIntervalSince1970
            mergeOrAppend(entry)
            saveToday()
        }

        currentStart       = Date()
        currentWindowTitle = title
        currentURL         = url
    }

    // 同一アプリ・同一URL・同一タイトルの連続エントリは endTime を伸ばしてマージ
    private func mergeOrAppend(_ entry: MacActivityEntry) {
        if let prev = completedEntries.last,
           Self.shouldMergeAdjacent(previous: prev, next: entry) {
            completedEntries[completedEntries.count - 1].endTime = entry.endTime
        } else {
            completedEntries.append(entry)
        }
    }

    static nonisolated func shouldMergeAdjacent(previous: MacActivityEntry, next: MacActivityEntry, maxGap: TimeInterval = 30) -> Bool {
        previous.appName == next.appName &&
        previous.url == next.url &&
        previous.windowTitle == next.windowTitle &&
        next.startTime - previous.endTime < maxGap
    }

    static nonisolated func buildLabel(appName: String, windowTitle: String) -> String {
        windowTitle.isEmpty ? appName : "\(appName) — \(windowTitle)"
    }

    // MARK: - ウィンドウタイトル + URL 取得（Accessibility API）

    /// タイトルと URL を取得。isBrowser=false の場合は URL 検索をスキップ。
    private static nonisolated func fetchWindowTitleAndURL(pid: pid_t, isBrowser: Bool) -> (title: String, url: String) {
        let axApp = AXUIElementCreateApplication(pid)
        var windowRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, "AXFocusedWindow" as CFString, &windowRef) == .success,
              let window = windowRef else { return ("", "") }
        let windowElement = window as! AXUIElement

        var titleRef: AnyObject?
        let title: String = AXUIElementCopyAttributeValue(windowElement, "AXTitle" as CFString, &titleRef) == .success
            ? (titleRef as? String ?? "") : ""

        guard isBrowser else { return (title, "") }

        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(windowElement, "AXChildren" as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return (title, "") }

        let url = findURLField(in: children, depth: 0) ?? ""
        return (title, url)
    }

    /// AXSubrole == "AXURLField" のテキストフィールドを再帰検索してURLを返す。
    /// ブラウザのアドレスバーはこのサブロールを持つ。
    private static nonisolated func findURLField(in elements: [AXUIElement], depth: Int) -> String? {
        guard depth < 8 else { return nil }
        for element in elements {
            var subroleRef: AnyObject?
            AXUIElementCopyAttributeValue(element, "AXSubrole" as CFString, &subroleRef)
            if let subrole = subroleRef as? String, subrole == "AXURLField" {
                var valueRef: AnyObject?
                if AXUIElementCopyAttributeValue(element, "AXValue" as CFString, &valueRef) == .success,
                   let urlStr = valueRef as? String, !urlStr.isEmpty {
                    return urlStr
                }
            }
            var childrenRef: AnyObject?
            if AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement], !children.isEmpty {
                if let found = findURLField(in: children, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    // MARK: - ディスク読み込み（nonisolated: actor外から呼べる）

    /// 今日のキャッシュファイルをディスクから直接読む（ブリーフ文脈用途）。
    nonisolated func todayEntriesFromDisk() -> [MacActivityEntry] {
        let home = NSHomeDirectory()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        let path = "\(home)/.hermes/mac-activity-\(f.string(from: Date())).json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let entries = try? JSONDecoder().decode([MacActivityEntry].self, from: data)
        else { return [] }
        return entries
    }

    // MARK: - 永続化（日次）

    private func loadToday() {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: cacheFilePath)),
           let entries = try? JSONDecoder().decode([MacActivityEntry].self, from: data) {
            completedEntries = entries
        }
    }

    private func saveToday() {
        let url = URL(fileURLWithPath: cacheFilePath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(completedEntries) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func dayKey(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }
}
