import Foundation

// アプリのprovider idを Hermes 設定へ橋渡しするルーティングを分離（#3 分割の継続）。
// base URL/モデルURL/表示名の解決と writeHermesModelConfig。依存は HermesCLI(外部)/in-block。
extension AppState {
    // MARK: - Inference provider routing (app provider id → Hermes config)

    /// The OpenAI-compatible base URL written to Hermes `model.base_url` for an app
    /// provider. "" means "let Hermes use its built-in default for this provider".
    static func providerBaseURL(_ provider: String) -> String {
        switch provider {
        case "openrouter": return "https://openrouter.ai/api/v1"
        case "cerebras":   return "https://api.cerebras.ai/v1"
        default:           return ""
        }
    }

    /// The value written to Hermes `model.provider`. Cerebras is NOT a built-in Hermes
    /// provider, so it routes through Hermes' generic "custom" path: model.provider=custom
    /// + base_url=api.cerebras.ai, where Hermes derives CEREBRAS_API_KEY from the host
    /// (hermes_cli/runtime_provider._host_derived_api_key). Verified against hermes v0.17.
    static func hermesProviderId(_ provider: String) -> String {
        provider == "cerebras" ? "custom" : provider
    }

    /// api_mode to pin for OpenAI chat-completions providers (nil = let Hermes auto-detect).
    static func providerAPIMode(_ provider: String) -> String? {
        switch provider {
        case "openrouter", "cerebras": return "chat_completions"
        default:                       return nil
        }
    }

    /// The OpenAI-compatible model-catalog endpoint for a provider (for the picker).
    static func providerModelsURL(_ provider: String) -> String? {
        let base = providerBaseURL(provider)
        return base.isEmpty ? nil : base + "/models"
    }

    /// Human-readable provider name for user-facing messages.
    static func providerDisplayName(_ provider: String) -> String {
        switch provider {
        case "openrouter":   return "OpenRouter"
        case "cerebras":     return "Cerebras"
        case "openai":       return "OpenAI"
        case "anthropic":    return "Anthropic"
        case "gemini":       return "Google Gemini"
        case AntigravityCLI.providerId: return "Antigravity"
        default:             return provider.isEmpty ? "選択中のプロバイダー" : provider
        }
    }

    /// Write the full Hermes model config for an app provider + model in one place:
    /// handles the cerebras→custom routing, base_url, api_mode, and clears a stale
    /// `model.api_key` on the custom route so Hermes resolves the host-derived key
    /// (a leftover key would otherwise leak to the wrong endpoint — verified). Antigravity
    /// is a separate backend and must never be written into the Hermes config.
    func writeHermesModelConfig(provider: String, model: String) async {
        guard provider != AntigravityCLI.providerId else { return }
        let hermesProvider = AppState.hermesProviderId(provider)
        _ = await HermesCLI.shared.exec(args: ["config", "set", "model.provider", hermesProvider])
        _ = await HermesCLI.shared.exec(args: ["config", "set", "model.default", model])
        _ = await HermesCLI.shared.exec(args: ["config", "set", "model.base_url", AppState.providerBaseURL(provider)])
        if let mode = AppState.providerAPIMode(provider) {
            _ = await HermesCLI.shared.exec(args: ["config", "set", "model.api_mode", mode])
        }
        // Custom route (cerebras): clear any persisted model.api_key so Hermes falls through
        // to the host-derived CEREBRAS_API_KEY instead of leaking a stale OpenRouter key.
        if hermesProvider == "custom" {
            _ = await HermesCLI.shared.exec(args: ["config", "set", "model.api_key", ""])
        }
    }

}
