import SwiftUI

// MARK: - Color(hex:)

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b: Double
        if s.count == 6 {
            r = Double((v & 0xFF0000) >> 16) / 255
            g = Double((v & 0x00FF00) >> 8) / 255
            b = Double(v & 0x0000FF) / 255
        } else {
            r = 0.5; g = 0.5; b = 0.5
        }
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Role catalog (selectable when hiring)

/// The role of an AI employee. Each role carries its own default model, mode,
/// accent color and persona (system directive). Picked from a fixed catalog when
/// hiring — see `CompanyView` / `AppState.hireEmployee`.
enum EmployeeRole: String, Codable, CaseIterable, Identifiable {
    case manager, engineer, researcher, writer, designer, analyst, reviewer, assistant
    var id: String { rawValue }

    /// Hiring order shown in the UI (manager first).
    static var catalog: [EmployeeRole] {
        [.manager, .engineer, .researcher, .writer, .designer, .analyst, .reviewer, .assistant]
    }

    var title: String {
        switch self {
        case .manager: return "マネージャー"
        case .engineer: return "エンジニア"
        case .researcher: return "リサーチャー"
        case .writer: return "ライター"
        case .designer: return "デザイナー"
        case .analyst: return "アナリスト"
        case .reviewer: return "レビュアー"
        case .assistant: return "アシスタント"
        }
    }

    var emoji: String {
        switch self {
        case .manager: return "🧑‍💼"
        case .engineer: return "👩‍💻"
        case .researcher: return "🔬"
        case .writer: return "✍️"
        case .designer: return "🎨"
        case .analyst: return "📊"
        case .reviewer: return "🛡️"
        case .assistant: return "🗂️"
        }
    }

    var blurb: String {
        switch self {
        case .manager: return "委譲・進捗・レビュー"
        case .engineer: return "実装・デバッグ"
        case .researcher: return "調査・要約"
        case .writer: return "文章・資料"
        case .designer: return "画像・デザイン"
        case .analyst: return "データ・表計算"
        case .reviewer: return "品質・QA"
        case .assistant: return "予定・雑務"
        }
    }

    var accentHex: String {
        switch self {
        case .manager: return "7F77DD"   // purple (leadership)
        case .engineer: return "378ADD"  // blue
        case .researcher: return "1D9E75" // teal
        case .writer: return "BA7517"    // amber
        case .designer: return "D4537E"  // pink
        case .analyst: return "639922"   // green
        case .reviewer: return "D85A30"  // coral
        case .assistant: return "888780" // gray
        }
    }

    var color: Color { Color(hex: accentHex) }

    var defaultMode: AgentMode {
        switch self {
        case .engineer, .designer, .analyst, .reviewer: return .code
        default: return .chat
        }
    }

    var defaultProvider: String { "openrouter" }

    /// Default model per role (cost-aware): leadership/coding → strong, others → cheap.
    var defaultModel: String {
        switch self {
        case .manager, .engineer, .reviewer: return "anthropic/claude-sonnet-4.5"
        case .researcher: return "google/gemini-3.5-flash"
        case .writer, .analyst: return "openai/gpt-4o-mini"
        case .designer: return "openai/gpt-4o-mini"
        case .assistant: return "nvidia/nemotron-3-super-120b-a12b:free"
        }
    }

    /// Role persona — steers behavior. Appended to each prompt (sentinel-stripped from display).
    var persona: String {
        switch self {
        case .manager:
            return "あなたは社内のマネージャーです。タスクを分解し、適切な担当（エンジニア/リサーチャー/ライター/デザイナー/アナリスト/レビュアー/アシスタント）へ委譲する方針を立て、進捗と品質を管理します。自分で抱え込みすぎず、誰に何を任せるかを明確にし、成果をレビューしてまとめます。"
        case .engineer:
            return "あなたはソフトウェアエンジニアです。コーディング・実装・デバッグ・リファクタリングを担当し、必要なツール（ファイル編集・ターミナル）を積極的に使って最後までやり切ります。変更は簡潔で、既存コードの作法に合わせます。"
        case .researcher:
            return "あなたはリサーチャーです。Web検索や資料調査で事実を集め、出典を明示し、要点を簡潔に要約します。推測と事実を区別します。コードの編集や実行は基本的に行いません。"
        case .writer:
            return "あなたはライターです。わかりやすく整った文章・ドキュメント・コピーを作成します。構成を整え、トーンを目的に合わせます。コードの編集や実行は基本的に行いません。"
        case .designer:
            return "あなたはデザイナーです。ビジュアル・画像・UIの提案とデザインを担当します。画像生成やレイアウトの具体案を出します。"
        case .analyst:
            return "あなたはアナリストです。データの集計・分析・表計算・可視化を担当し、数字に基づいて示唆を述べます。前提と計算過程を明示します。"
        case .reviewer:
            return "あなたはレビュアー/QA担当です。コードや成果物の品質・バグ・抜け漏れを批判的に点検し、根拠とともに具体的な修正提案を出します。"
        case .assistant:
            return "あなたはアシスタントです。予定調整・リマインド・情報整理・雑務など、日常的なサポートを丁寧かつ簡潔に行います。"
        }
    }
}

// MARK: - Teams & tasks

/// A team/department grouping employees (Phase A — org & teams).
struct Team: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var managerId: String? = nil   // an employee (role .manager) who leads the team
    /// Last edit time of the shared fields (for cloud last-write-wins).
    /// Optional so existing persisted teams decode without it. nil → treated as 0.
    var updatedAt: Double? = nil
}

/// Task board status (Phase B).
enum TaskStatus: String, Codable, CaseIterable, Identifiable {
    case todo, doing, done
    var id: String { rawValue }
    var title: String { self == .todo ? "未着手" : (self == .doing ? "対応中" : "完了") }
    var icon: String { self == .todo ? "tray" : (self == .doing ? "bolt" : "checkmark.circle") }
}

/// A work item assignable to an employee (Phase B — task board).
struct WorkTask: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var title: String
    var detail: String = ""
    var assigneeId: String? = nil
    var status: TaskStatus = .todo
    var createdAt: Double = Date().timeIntervalSince1970
    var updatedAt: Double = Date().timeIntervalSince1970
}

// MARK: - Employee

/// A hired AI employee. Holds its own model/persona/mode/workspace and — critically —
/// its own hermes session id so each employee's conversation context stays isolated.
struct Employee: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var role: EmployeeRole
    var provider: String
    var model: String
    var mode: AgentMode
    var personaOverride: String? = nil
    /// Path to an AI-generated/cached avatar image; nil → draw a deterministic tile.
    var avatarImagePath: String? = nil
    /// Per-employee working folder (cwd). nil → falls back to the app default.
    var workspacePath: String? = nil
    /// Team membership (Phase A). Optional → existing persisted employees decode fine.
    var teamId: String? = nil
    /// The employee's current hermes session (context isolation). nil → fresh.
    var sessionId: String? = nil
    var createdAt: Double = Date().timeIntervalSince1970
    /// Last edit time of the SHARED profile fields (for cloud last-write-wins).
    /// Optional so existing persisted employees decode without it. nil → use createdAt.
    var updatedAt: Double? = nil

    var persona: String { personaOverride ?? role.persona }

    /// 1–2 char initials for the deterministic avatar tile.
    var initials: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return role.emoji }
        return String(first).uppercased()
    }

    static func make(name: String, role: EmployeeRole) -> Employee {
        Employee(name: name, role: role, provider: role.defaultProvider,
                 model: role.defaultModel, mode: role.defaultMode)
    }
}
