import Foundation

// チャンネル(配信先)管理を AppState 本体から分離（#3 god object 分割の継続）。
// @Published channels / newChannel* は stored property のため AppState 本体に残し、
// 取得/追加/削除/テスト送信のロジックをここへ集約した。channelDirectoryURL も内部限定。
extension AppState {
    // MARK: - Channels (messaging recipients)

    private var channelDirectoryURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermes/channel_directory.json")
    }

    func fetchChannels() {
        guard let data = try? Data(contentsOf: channelDirectoryURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let platforms = json["platforms"] as? [String: Any] else {
            self.channels = []
            return
        }
        var result: [HermesChannel] = []
        for (platform, value) in platforms {
            guard let list = value as? [[String: Any]] else { continue }
            for item in list {
                let cid = (item["id"] as? String) ?? (item["id"] as? Int).map(String.init) ?? ""
                guard !cid.isEmpty else { continue }
                result.append(HermesChannel(
                    platform: platform,
                    channelId: cid,
                    name: (item["name"] as? String) ?? cid,
                    type: (item["type"] as? String) ?? "dm"
                ))
            }
        }
        self.channels = result.sorted { $0.platform < $1.platform }
    }

    func addChannel() {
        let platform = newChannelPlatform.trimmingCharacters(in: .whitespacesAndNewlines)
        let cid = newChannelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = newChannelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !platform.isEmpty, !cid.isEmpty else {
            triggerToast(message: "プラットフォームとIDを入力してください。")
            return
        }

        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: channelDirectoryURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }
        var platforms = (json["platforms"] as? [String: Any]) ?? [:]
        var list = (platforms[platform] as? [[String: Any]]) ?? []
        if !list.contains(where: { ($0["id"] as? String) == cid }) {
            list.append(["id": cid, "name": name.isEmpty ? cid : name, "type": "dm", "thread_id": NSNull()])
        }
        platforms[platform] = list
        json["platforms"] = platforms
        json["updated_at"] = ISO8601DateFormatter().string(from: Date())

        do {
            let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
            try out.write(to: channelDirectoryURL)
            triggerToast(message: "チャンネルを追加しました。")
            newChannelId = ""
            newChannelName = ""
            fetchChannels()
        } catch {
            reportFailure("チャンネル設定の保存に失敗 (\(channelDirectoryURL.path))", error: error,
                          toast: "チャンネルの保存に失敗しました。")
        }
    }

    func removeChannel(_ channel: HermesChannel) {
        guard let data = try? Data(contentsOf: channelDirectoryURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var platforms = json["platforms"] as? [String: Any],
              var list = platforms[channel.platform] as? [[String: Any]] else { return }
        list.removeAll { ($0["id"] as? String) == channel.channelId }
        platforms[channel.platform] = list
        json["platforms"] = platforms
        json["updated_at"] = ISO8601DateFormatter().string(from: Date())
        do {
            let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
            try out.write(to: channelDirectoryURL)
            fetchChannels()
        } catch {
            reportFailure("チャンネル設定の保存に失敗 (\(channelDirectoryURL.path))", error: error,
                          toast: "チャンネルの削除を保存できませんでした。")
        }
    }

    func testSendChannel(_ channel: HermesChannel) async {
        triggerToast(message: "\(channel.name) にテスト送信中...")
        let message = "Hermes Agent テスト通知です ✅"
        let res: (success: Bool, stdout: String, stderr: String)
        if channel.platform.lowercased() == "line" {
            // LINE is wired through the custom bridge (line-send.sh) in this setup,
            // not `hermes send` (which has no LINE home channel and would error).
            let script = NSHomeDirectory() + "/.hermes/line-bridge/line-send.sh"
            res = await HermesCLI.shared.execCommand("/bin/bash", [script, channel.channelId, message])
        } else {
            let target = "\(channel.platform):\(channel.channelId)"
            res = await HermesCLI.shared.exec(args: ["send", "-t", target, message])
        }
        if res.success {
            triggerToast(message: "送信しました。")
        } else {
            // Surface the actual reason instead of a generic failure.
            let err = (res.stderr.isEmpty ? res.stdout : res.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            triggerToast(message: "送信に失敗: \(String(err.prefix(90)))")
        }
    }
}
