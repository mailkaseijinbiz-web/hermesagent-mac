import Foundation
import AppKit

// Antigravity(agy)プロンプト整形・固定プロバイダのモデル解決・AIアバター生成を分離（#3 分割の継続）。
// 依存(AntigravityCLI/defaultModel/triggerToast)は外部/internal。
extension AppState {
    // MARK: - Antigravity CLI backend (agy)

    /// Build a plain (sentinel-free) prompt for `agy`, prepending the employee persona
    /// and appending the chat/code mode directive as plain text. Antigravity won't strip
    /// Hermes sentinels, so the directive is included verbatim (not sentinel-wrapped).
    func antigravityPrompt(_ text: String, employee: Employee?, mode: AgentMode) -> String {
        var prefix = ""
        if let emp = employee {
            prefix += "あなたは「\(emp.name)」という名前の\(emp.role.title)です。\(emp.persona)\n\n"
        }
        return "\(prefix)\(text)\n\n\(mode.directive)"
    }

    /// The model to run under the FIXED global provider. The provider is a Settings-only
    /// value (never auto-switched), so an employee's own model is honored only when it
    /// belongs to that provider; otherwise we fall back to the global default model.
    func modelForFixedProvider(_ employee: Employee?) -> String {
        if let e = employee, e.provider == provider, !e.model.isEmpty { return e.model }
        if !defaultModel.isEmpty { return defaultModel }
        return provider == AntigravityCLI.providerId ? AntigravityCLI.defaultModel : defaultModel
    }

    /// Generate an AI avatar via Pollinations (free, no key) and cache it to disk.
    func generateAIAvatar(for employeeId: String) async {
        guard let emp = employees.first(where: { $0.id == employeeId }) else { return }
        let english: [EmployeeRole: String] = [
            .manager: "business manager", .engineer: "software engineer", .researcher: "researcher",
            .writer: "writer", .designer: "designer", .analyst: "data analyst",
            .reviewer: "quality reviewer", .assistant: "personal assistant"
        ]
        let role = english[emp.role] ?? "office worker"
        let promptText = "professional friendly corporate avatar portrait of a \(role), flat vector illustration, centered, simple solid background"
        let enc = promptText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? promptText
        // Vary the seed each generation so re-generating yields a fresh portrait.
        let stamp = Int(Date().timeIntervalSince1970)
        guard let url = URL(string: "https://image.pollinations.ai/prompt/\(enc)?width=256&height=256&nologo=true&seed=\(stamp)") else { return }
        do {
            var req = URLRequest(url: url); req.timeoutInterval = 60
            let (data, _) = try await URLSession.shared.data(for: req)
            guard NSImage(data: data) != nil else { triggerToast(message: "アバター生成に失敗しました"); return }
            let dir = avatarsDir()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Unique filename so SwiftUI/NSImage reload (stable path + NSImage cache would not).
            let path = dir.appendingPathComponent("\(employeeId)-\(stamp).png")
            try data.write(to: path)
            if let idx = employees.firstIndex(where: { $0.id == employeeId }) {
                let old = employees[idx].avatarImagePath
                employees[idx].avatarImagePath = path.path
                if let old = old, old != path.path { try? FileManager.default.removeItem(atPath: old) }
            }
            triggerToast(message: "アバターを生成しました")
        } catch {
            triggerToast(message: "アバター生成に失敗しました")
        }
    }

    func avatarsDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HermesCustom/avatars", isDirectory: true)
    }

}
