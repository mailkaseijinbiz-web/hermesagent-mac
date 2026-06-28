import Foundation

// 「LINEに〜を送って」等のチャット指示からチャンネル送信する機能を分離（#3 分割の継続）。
// 依存(channels/HermesCLI)は internal/外部。private helperは同ファイル内のみ。
extension AppState {
    // MARK: - Send to a channel from a chat prompt ("LINEに〜を送って")

    /// Deliver `text` to a registered channel (LINE via the bridge's line-send.sh; others via
    /// `hermes send`). Returns success + an error detail.
    func sendToChannel(_ channel: HermesChannel, text: String) async -> (ok: Bool, detail: String) {
        let res: (success: Bool, stdout: String, stderr: String)
        if channel.platform.lowercased() == "line" {
            let script = NSHomeDirectory() + "/.hermes/line-bridge/line-send.sh"
            res = await HermesCLI.shared.execCommand("/bin/bash", [script, channel.channelId, text])
        } else {
            let target = "\(channel.platform):\(channel.channelId)"
            res = await HermesCLI.shared.exec(args: ["send", "-t", target, text])
        }
        let err = (res.stderr.isEmpty ? res.stdout : res.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return (res.success, err)
    }

    /// Detect a "send this to LINE" instruction in a chat prompt and extract the recipient
    /// channel + the message body. Returns nil when it isn't a clear send command (so the
    /// prompt falls through to the AI as usual). Conservative: requires BOTH a LINE/ライン
    /// mention and an explicit send verb.
    /// True if the prompt reads as a LINE-send instruction (LINE/ライン mention + a send verb,
    /// and not a how-to question). Channel-agnostic so the caller can surface "no channel".
    func looksLikeLineSend(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 4, t.count < 2000, !t.contains("\n\n") else { return false }
        guard t.lowercased().contains("line") || t.contains("ライン") else { return false }
        let sendVerbs = ["送って", "送信", "送る", "送っといて", "送っておいて", "プッシュ", "通知して", "通知", "メッセージして", "伝えて", "知らせて"]
        guard sendVerbs.contains(where: { t.contains($0) }) else { return false }
        // Reject "how-to" questions and conditional/recurring phrasing (unless an explicit quote
        // pins the exact message text). 条件・反復表現（「〜たら」「定期的に」「毎日」など）は
        // 一回限りの送信ではなく『自動化を組んでほしい』という意図なので、文字通り送らない。
        if !t.contains("「") && !t.contains("『") {
            let howTo = ["使い方", "とは", "教えて", "どうやって", "方法", "設定", "繋ぎ方", "つなぎ方", "連携", "とは何"]
            let automationCues = ["たら", "次第", "毎日", "毎時", "毎週", "毎朝", "毎晩", "定期", "ごとに", "都度", "監視", "あれば", "出たら"]
            for q in howTo + automationCues where t.contains(q) {
                return false
            }
        }
        return true
    }

    func parseLineSendCommand(_ text: String) -> (channel: HermesChannel, message: String)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeLineSend(t) else { return nil }
        let lineChannels = channels.filter { $0.platform.lowercased() == "line" }
        guard !lineChannels.isEmpty else { return nil }   // caller surfaces "no LINE channel"
        // Prefer a channel whose name is explicitly mentioned; else the only/first one.
        let target = lineChannels.first { $0.name.count >= 2 && t.contains($0.name) } ?? lineChannels[0]
        guard let msg = extractSendMessage(t), !msg.isEmpty else { return nil }
        return (target, msg)
    }

    /// Best-effort extraction of the message body from a send command (handles quoted text and
    /// both "LINEに〜送って" and "〜をLINEに送って" forms).
    private func extractSendMessage(_ t: String) -> String? {
        // 1) Quoted content wins.
        for (open, close) in [("「", "」"), ("『", "』"), ("\u{201C}", "\u{201D}"), ("\"", "\"")] {
            if let o = t.range(of: open), let c = t.range(of: close, range: o.upperBound..<t.endIndex) {
                let inner = String(t[o.upperBound..<c.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !inner.isEmpty { return inner }
            }
        }
        // 2) "<message> (を|と|って) LINE(に|へ|で) 送って" — message is BEFORE the LINE framing.
        let trailing = #"\s*(を|と|って)?\s*(line|ライン)\s*(に|へ|で|宛て?に)\s*(送信|送って|送る|送っ|通知|プッシュ|メッセージ|伝え|知らせ).*$"#
        if let r = t.range(of: trailing, options: [.regularExpression, .caseInsensitive]) {
            let before = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if before.count >= 1 { return stripEdgeParticles(before) }
        }
        // 3) "LINE(に|へ|で) <message> (を) 送って" — message is AFTER the LINE marker.
        var s = t
        for marker in ["LINEに", "LINEへ", "LINEで", "ラインに", "ラインへ", "ラインで", "lineに", "lineで", "lineへ", "LINE", "ライン", "line"] {
            if let r = s.range(of: marker, options: [.caseInsensitive]) { s = String(s[r.upperBound...]); break }
        }
        for tail in ["。", "．", ".", "！", "!", "してください", "して下さい", "してね", "しておいて", "しといて",
                     "して", "お願いします", "おねがいします", "お願い", "よろしく", "を送信", "を送って",
                     "を送る", "を通知", "とメッセージ", "と送って", "って送って", "を伝えて", "と伝えて",
                     "を知らせて", "送信", "送って", "通知", "プッシュ"] {
            while s.hasSuffix(tail) { s = String(s.dropLast(tail.count)).trimmingCharacters(in: .whitespaces) }
        }
        return stripEdgeParticles(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func stripEdgeParticles(_ s: String) -> String? {
        var r = s
        for tail in ["を", "と", "、", ",", "って", "は", "に"] {
            while r.hasSuffix(tail) { r = String(r.dropLast(tail.count)).trimmingCharacters(in: .whitespaces) }
        }
        r = r.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.isEmpty ? nil : r
    }

}
