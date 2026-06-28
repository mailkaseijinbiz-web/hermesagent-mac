import Foundation

// モデル/プロバイダーの検証・適用を AppState 本体から分離（#3 god object 分割の継続）。
// 依存(writeHermesModelConfig/applyModelSilently/triggerToast/loadApiKey 等)はすべて internal。
extension AppState {
    // MARK: - Model validation (hide non-working models)

    /// Test an OpenRouter model with a 1-token request; record + return whether it works.
    /// Only a definitive client error (400/401/402/403/404) marks a model broken — transient
    /// conditions (429/5xx/timeout) leave health unknown so a model isn't wrongly hidden.
    /// Note: this is a real (billable) completion for paid models.
    @discardableResult
    func validateModel(_ id: String) async -> Bool {
        // Validate against the CURRENT provider's OpenAI-compatible endpoint.
        let base = AppState.providerBaseURL(provider)
        let key = HermesCLI.shared.getApiKey(provider: provider)
        guard !key.isEmpty, !base.isEmpty, let url = URL(string: base + "/chat/completions") else {
            return modelHealth[id] ?? true   // no key / non-HTTP provider → can't test; leave unknown
        }
        validatingModelId = id
        defer { if validatingModelId == id { validatingModelId = nil } }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Validate the way the app actually uses the model: as a tool-using agent. A model
        // whose OpenRouter providers don't support tool calling returns 404 ("No endpoints
        // found that support tool use"), which the 4xx branch below correctly marks unusable.
        // (A plain no-tools ping would pass and wrongly show such a model as working — the
        // exact gap that let `aion-labs/aion-1.0` be selected.)
        let body: [String: Any] = [
            "model": id,
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 1,
            "tools": [[
                "type": "function",
                "function": ["name": "ping", "description": "noop",
                             "parameters": ["type": "object", "properties": [String: Any]()]]
            ]]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let bodyStr = (String(data: data, encoding: .utf8) ?? "").lowercased()
            if code == 200 {
                var works = true
                if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], j["error"] != nil { works = false }
                modelHealth[id] = works
                return works
            }
            // No tool-capable provider → unusable in this agent (which always uses tools).
            if bodyStr.contains("support tool use") {
                modelHealth[id] = false
                return false
            }
            // Hit the tiny max_tokens cap → the model accepted the tools request and started
            // generating, so it IS reachable & tool-capable (don't mis-flag it as broken).
            if code == 400, bodyStr.contains("max_tokens") || bodyStr.contains("output limit") || bodyStr.contains("finish") {
                modelHealth[id] = true
                return true
            }
            if [400, 401, 402, 403, 404].contains(code) {
                modelHealth[id] = false   // bad model / no access / no credits → unusable
                return false
            }
            return modelHealth[id] ?? true   // 429/5xx etc → transient, keep prior/unknown
        } catch {
            return modelHealth[id] ?? true   // timeout/network → unknown, don't mark broken
        }
    }

    /// Re-validate the recommended presets (+ the default when on OpenRouter). Runs the
    /// pings concurrently and keeps the set small/fast.
    func revalidatePresets() async {
        isValidatingModels = true
        defer { isValidatingModels = false }
        var ids = Set(currentModelPresets.map { $0.model })
        // Include the active model only when it belongs to the current HTTP provider
        // (don't test a non-matching id against the wrong endpoint).
        if !AppState.providerBaseURL(provider).isEmpty { ids.insert(defaultModel) }
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { [weak self] in _ = await self?.validateModel(id) } }
        }
        triggerToast(message: "おすすめモデルを検証しました")
    }

    /// True if the model is proven non-working AND the hide toggle is on. The currently
    /// selected model is never hidden (so the user can always see their own choice).
    func modelIsHidden(_ id: String) -> Bool { id != defaultModel && hideBrokenModels && modelHealth[id] == false }

    /// Quietly apply a model under the FIXED provider (no toast) — used on employee switch.
    /// The inference provider is a Settings-only value (see `handleProviderChange`) and is
    /// never changed here, so switching employees can't silently flip the provider.
    func applyModelSilently(model: String) async {
        self.defaultModel = model
        // Antigravity runs via `agy`, not Hermes — never write it into the Hermes config
        // (it's not a Hermes provider, and doing so would break Hermes-backed employees).
        guard provider != AntigravityCLI.providerId else { return }
        await writeHermesModelConfig(provider: provider, model: model)
        await loadApiKey()
    }

    /// Switch the active MODEL from the composer/picker, persisting to the CLI config.
    /// The provider stays the fixed global one — only Settings changes the provider.
    func setModel(_ model: String) async {
        await applyModelSilently(model: model)
        // Persist onto the active employee (with the fixed provider) so it follows them.
        if let empId = activeEmployeeId, let idx = employees.firstIndex(where: { $0.id == empId }) {
            employees[idx].provider = provider
            employees[idx].model = model
            employees[idx].updatedAt = Date().timeIntervalSince1970
            if cloudSyncEnabled { Task { await pushEmployees() } }
        }
        triggerToast(message: "モデルを変更しました: \(model)")
    }

    /// Set just the model id (for custom entry). Provider is fixed via Settings.
    func setCustomModel(_ model: String) async {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await setModel(trimmed)
    }

    // Provider selection helper
    func handleProviderChange(_ newProvider: String) {
        self.provider = newProvider
        switch newProvider {
        case "openrouter":
            self.defaultModel = "nvidia/nemotron-3-super-120b-a12b:free"
        case "cerebras":
            self.defaultModel = "gpt-oss-120b"
        case "openai":
            self.defaultModel = "gpt-4o-mini"
        case "anthropic":
            self.defaultModel = "claude-3-5-sonnet-20241022"
        case "gemini":
            self.defaultModel = "gemini-2.5-flash"
        case "nous":
            self.defaultModel = "anthropic/claude-3-5-sonnet-latest"
        case "xai-oauth":
            self.defaultModel = "grok-beta"
        case "openai-codex":
            self.defaultModel = "code-davinci-002"
        case AntigravityCLI.providerId:
            self.defaultModel = AntigravityCLI.defaultModel
        default:
            break
        }

        // The model catalog is per-provider — drop the stale list and refetch for the new one.
        self.availableModels = []
        Task {
            await loadApiKey()
            await fetchAvailableModels()
        }
    }
    
    // Save Settings Config
    func handleSaveSettings() async {
        self.isSavingSettings = true

        // Antigravity runs via `agy`, not Hermes — skip the Hermes model config writes
        // (keep personality, which is display-only) and the API-key save (agy self-auths).
        if provider != AntigravityCLI.providerId {
            // Save the API key BEFORE writing the model config so the env var exists when
            // Hermes (host-derived key path for cerebras) next resolves the provider.
            if !["nous", "xai-oauth", "openai-codex"].contains(provider) {
                _ = HermesCLI.shared.saveApiKey(provider: provider, key: apiKey)
            }
            await writeHermesModelConfig(provider: provider, model: defaultModel)
            // The persistent ACP process(es) captured the OLD environment at spawn — recycle
            // the idle ones so the next prompt respawns with the freshly-saved key (e.g.
            // CEREBRAS_API_KEY). resetSession() only drops the session id and REUSES the running
            // process (stale env), so we must shutdown() to actually respawn. Streaming clients
            // are left intact. (The per-prompt Hermes CLI path always gets the latest env.)
            // The shared client is used only for delegation — don't kill it mid-delegation.
            if busyEmployeeIds.isEmpty { ACPClient.shared.shutdown() }
            for key in empACPClients.keys where !streamingEmployeeIds.contains(key) {
                empACPClients[key]?.shutdown()
                empACPClients.removeValue(forKey: key)
            }
        }
        _ = await HermesCLI.shared.exec(args: ["config", "set", "display.personality", personality])

        triggerToast(message: "設定を保存しました。")
        await fetchConfig()
        self.isSavingSettings = false
    }
    
    // Trigger OAuth Auth command
    func triggerOAuthLogin() async {
        triggerToast(message: "ブラウザを起動して認証を開始します...")
        let res = await HermesCLI.shared.exec(args: ["auth", "add", provider, "--type", "oauth"])
        if res.success {
            triggerToast(message: "認証が完了しました。")
        } else {
            triggerToast(message: "認証エラーが発生しました。")
        }
    }
    
}
