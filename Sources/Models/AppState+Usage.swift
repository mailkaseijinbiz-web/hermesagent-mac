import Foundation

// コスト/使用量(Phase 3)の派生ロジックを分離（#3 god object 分割の継続）。
// 集計データ(@Published usageByEmployee/totalTokens/totalCostUSD/monthlyBudgetUSD)は stored の
// ため AppState 本体に残し、予算派生プロパティ・レート表・refreshUsage をここへ集約。
extension AppState {
    /// Spend as a fraction of budget (capped at 1.0 for the bar fill).
    var budgetFraction: Double { monthlyBudgetUSD > 0 ? min(totalCostUSD / monthlyBudgetUSD, 1.0) : 0 }
    /// Uncapped ratio (so >1.0 means over budget).
    var budgetRatio: Double { monthlyBudgetUSD > 0 ? totalCostUSD / monthlyBudgetUSD : 0 }
    /// 0 = ok, 1 = warning (>=80%), 2 = over (>=100%).
    var budgetState: Int { monthlyBudgetUSD <= 0 ? 0 : (budgetRatio >= 1.0 ? 2 : (budgetRatio >= 0.8 ? 1 : 0)) }
    /// Start of the current calendar month (epoch seconds).
    private var startOfMonthEpoch: Double {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: Date()))?.timeIntervalSince1970 ?? 0
    }

    /// Rough blended price ($ per 1M tokens, in+out averaged) per model — for estimates only.
    static func blendedRatePerMTok(_ model: String) -> Double {
        let m = model.lowercased()
        if m.contains(":free") || m.contains("nemotron") { return 0 }
        if m.contains("claude") && m.contains("opus") { return 30 }
        if m.contains("claude") && m.contains("sonnet") { return 9 }
        if m.contains("claude") && m.contains("haiku") { return 2.5 }
        if m.contains("gpt-4o-mini") || m.contains("4.1-mini") || m.contains("4o-mini") { return 0.4 }
        if m.contains("gpt-4o") || m.contains("gpt-4.1") || m.contains("o3") { return 6 }
        if m.contains("gemini") && m.contains("flash") { return 0.2 }
        if m.contains("gemini") && m.contains("pro") { return 3 }
        return 1.0   // unknown model → conservative default
    }

    /// Recompute THIS MONTH's per-employee tokens + estimated cost from state.db.
    func refreshUsage() {
        let totals = StateDB.shared.tokenTotalsBySession(since: startOfMonthEpoch)
        var byEmp: [String: EmployeeUsage] = [:]
        for emp in employees {
            var sids = Set(sessionOwner.filter { $0.value == emp.id }.map { $0.key })
            if let cur = emp.sessionId { sids.insert(cur) }
            var u = EmployeeUsage()
            for sid in sids {
                let t = totals[sid] ?? 0
                if t > 0 { u.tokens += t; u.sessions += 1 }
            }
            u.costUSD = Double(u.tokens) / 1_000_000 * AppState.blendedRatePerMTok(emp.model)
            byEmp[emp.id] = u
        }
        usageByEmployee = byEmp
        totalTokens = byEmp.values.reduce(0) { $0 + $1.tokens }
        totalCostUSD = byEmp.values.reduce(0) { $0 + $1.costUSD }
    }
}
