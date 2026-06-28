import Foundation

// 管理(skills/MCP/memory/plugins)のロジックを分離（#3 分割の継続）。
// @Published skills/isFetchingSkills/mcpRawOutput は本体残置。parsePluginsList は internal 化済み。
extension AppState {
    /// Load the installed skills list (`hermes skills list`).
    func fetchSkills() async {
        isFetchingSkills = true
        let res = await HermesCLI.shared.exec(args: ["skills", "list"])
        if res.success { self.skills = Self.parseSkillsTable(res.stdout) }
        isFetchingSkills = false
    }

    /// Parse the rich-table skills output into rows (cols: name | category | source | trust | status).
    static func parseSkillsTable(_ s: String) -> [HermesSkill] {
        var out: [HermesSkill] = []
        for line in s.components(separatedBy: "\n") where line.contains("│") {
            let c = line.components(separatedBy: "│")
            guard c.count >= 6 else { continue }
            let name = c[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != "Name" else { continue }
            out.append(HermesSkill(
                id: name, name: name,
                category: c[2].trimmingCharacters(in: .whitespaces),
                source: c[3].trimmingCharacters(in: .whitespaces),
                status: c[5].trimmingCharacters(in: .whitespaces)
            ))
        }
        return out
    }

    /// Enable/disable a skill via opt-in / opt-out, then refresh.
    func toggleSkill(_ skill: HermesSkill) async {
        let cmd = skill.isEnabled ? "opt-out" : "opt-in"
        _ = await HermesCLI.shared.exec(args: ["skills", cmd, skill.name])
        await fetchSkills()
    }

    /// Load configured MCP servers (raw text; format varies / often empty).
    func fetchMCPServers() async {
        let res = await HermesCLI.shared.exec(args: ["mcp", "list"])
        self.mcpRawOutput = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Read a built-in memory document (empty string if absent).
    func loadMemory(_ f: MemoryFile) -> String {
        (try? String(contentsOfFile: f.path, encoding: .utf8)) ?? ""
    }

    /// Write a built-in memory document.
    func saveMemory(_ f: MemoryFile, _ content: String) {
        let url = URL(fileURLWithPath: f.path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            triggerToast(message: "\(f.rawValue) を保存しました")
        } catch {
            triggerToast(message: "保存に失敗しました")
        }
    }
    
    func parsePluginsList(stdout: String) -> [HermesPlugin] {   // internal: fetchPlugins (main) calls it after this moved to AppState+Management
        let lines = stdout.components(separatedBy: .newlines)
        var parsed: [HermesPlugin] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            
            let components = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if components.count >= 4 {
                var status = ""
                var source = ""
                var version = ""
                var name = ""

                if components[0] == "not" && components[1] == "enabled" && components.count >= 5 {
                    status = "not enabled"
                    source = components[2]
                    version = components[3]
                    name = components[4]
                } else if components[0] != "not" {
                    status = components[0]
                    source = components[1]
                    version = components[2]
                    name = components[3]
                }
                
                parsed.append(HermesPlugin(
                    id: name,
                    name: name,
                    status: status,
                    version: version,
                    source: source
                ))
            }
        }
        return parsed
    }
    
    func handleTogglePlugin(_ plugin: HermesPlugin) async {
        let action = plugin.isEnabled ? "disable" : "enable"
        let res = await HermesCLI.shared.exec(args: ["plugins", action, plugin.name])
        if res.success {
            triggerToast(message: "\(plugin.name) を\(plugin.isEnabled ? "無効" : "有効")にしました。")
            await fetchPlugins()
        } else {
            triggerToast(message: "操作に失敗しました。")
        }
    }
    
    func handleInstallPlugin() async {
        let url = pluginInstallInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        self.isInstallingPlugin = true
        triggerToast(message: "プラグインをインストール中...")
        let res = await HermesCLI.shared.exec(args: ["plugins", "install", url])
        if res.success {
            triggerToast(message: "インストールが完了しました。")
            self.pluginInstallInput = ""
            await fetchPlugins()
        } else {
            triggerToast(message: "インストールに失敗しました。")
        }
        self.isInstallingPlugin = false
    }
    
    func handleUninstallPlugin(_ plugin: HermesPlugin) async {
        triggerToast(message: "\(plugin.name) を削除中...")
        let res = await HermesCLI.shared.exec(args: ["plugins", "remove", plugin.name])
        if res.success {
            triggerToast(message: "削除が完了しました。")
            await fetchPlugins()
        } else {
            triggerToast(message: "削除に失敗しました。")
        }
    }
    

}
