import Foundation

struct MacMemo: Codable, Identifiable, Equatable {
    var id: String   = UUID().uuidString
    var text: String
    var time: Date
    var editedAt: Date? = nil
}

@MainActor
final class MacMemoStore: ObservableObject {
    static let shared = MacMemoStore()
    @Published var todayMemos: [MacMemo] = []
    private let key     = "macLifeLogMemos"
    private let dateKey = "macLifeLogMemosDate"
    init() { loadToday() }

    func addMemo(_ text: String, at time: Date = Date()) {
        todayMemos.append(MacMemo(text: text, time: time)); save()
    }
    func updateMemo(id: String, text: String) {
        guard let i = todayMemos.firstIndex(where: { $0.id == id }) else { return }
        todayMemos[i].text = text; todayMemos[i].editedAt = Date(); save()
    }
    func deleteMemo(id: String) { todayMemos.removeAll { $0.id == id }; save() }

    private func loadToday() {
        let today = dayKey(Date())
        if UserDefaults.standard.string(forKey: dateKey) != today {
            todayMemos = []; UserDefaults.standard.set(today, forKey: dateKey); save(); return
        }
        if let data = UserDefaults.standard.data(forKey: key),
           let m = try? JSONDecoder().decode([MacMemo].self, from: data) { todayMemos = m }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(todayMemos) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    private func dayKey(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX"); return f.string(from: d)
    }
}
