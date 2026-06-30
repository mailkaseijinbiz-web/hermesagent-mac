import SwiftUI

// MARK: - Schedule (Phase G — calendar)
//
// A month calendar for the company's events. Pick a day to see/add its events; events can
// be assigned to an employee (shown in their accent color).

struct ScheduleView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var gcal = GoogleCalendarSync.shared
    @Environment(\.colorScheme) var colorScheme
    @State private var month: Date = ScheduleView.startOfMonth(Date())
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: Date())
    @State private var editor: EventEditorTarget? = nil

    private let cal = Calendar.current
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    private let weekdaySymbols = ["日", "月", "火", "水", "木", "金", "土"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                monthBar
                weekdayHeader
                calendarGrid
                Divider().opacity(0.5)
                dayEvents
            }
            .padding(.horizontal, 32).padding(.top, 52).padding(.bottom, 24)
            .frame(maxWidth: 940)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .ignoresSafeArea(edges: .top)
        .sheet(item: $editor) { t in
            EventEditSheet(existing: t.existing, defaultDay: selectedDay).environmentObject(appState)
        }
    }

    // MARK: header / month navigation

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("スケジュール").font(.system(size: 24, weight: .bold))
                Text("予定をカレンダーで管理。日付を選んで予定を追加できます。")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            Spacer()
            Button { editor = EventEditorTarget(existing: nil) } label: {
                HStack(spacing: 6) { Image(systemName: "plus"); Text("予定を追加") }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(colorScheme == .dark ? Color.white : Color.black)
                    .foregroundColor(colorScheme == .dark ? .black : .white).cornerRadius(8)
            }.buttonStyle(.plain)
            Button { appState.view = "chat" } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary).frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06)).clipShape(Circle())
            }.buttonStyle(.plain)
        }
    }

    private var monthBar: some View {
        HStack(spacing: 12) {
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain).foregroundColor(.secondary)
            Text(monthTitle).font(.system(size: 15, weight: .semibold)).frame(minWidth: 120)
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain).foregroundColor(.secondary)
            Button {
                month = Self.startOfMonth(Date())
                selectedDay = cal.startOfDay(for: Date())
            } label: { Text("今日").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(.plain).foregroundColor(.blue)
            Spacer()
        }
    }

    private var weekdayHeader: some View {
        LazyVGrid(columns: cols, spacing: 4) {
            ForEach(0..<7, id: \.self) { i in
                Text(weekdaySymbols[i])
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(i == 0 ? .red.opacity(0.8) : (i == 6 ? .blue.opacity(0.8) : .secondary))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var calendarGrid: some View {
        LazyVGrid(columns: cols, spacing: 4) {
            ForEach(Array(monthDays.enumerated()), id: \.offset) { _, day in
                if let day = day { dayCell(day) }
                else { Color.clear.frame(height: 56) }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isToday = cal.isDateInToday(day)
        let isSelected = cal.isDate(day, inSameDayAs: selectedDay)
        let inMonth = cal.isDate(day, equalTo: month, toGranularity: .month)
        let weekday = cal.component(.weekday, from: day)   // 1=Sun..7=Sat
        let dayNum = cal.component(.day, from: day)
        return VStack(spacing: 3) {
            Text("\(dayNum)")
                .font(.system(size: 12, weight: isToday ? .bold : .regular))
                .foregroundColor(numberColor(weekday: weekday, inMonth: inMonth, isToday: isToday))
            if appState.hasEvents(on: day) || !gcal.events(on: day).isEmpty {
                Circle().fill(Color.blue).frame(width: 5, height: 5)
            } else {
                Spacer().frame(height: 5)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity).frame(height: 56)
        .background(isSelected ? Color.blue.opacity(0.14) : (isToday ? Color.primary.opacity(0.05) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.blue.opacity(0.5) : Color.clear, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { selectedDay = day }
    }

    private func numberColor(weekday: Int, inMonth: Bool, isToday: Bool) -> Color {
        if isToday { return .blue }
        let base: Color = weekday == 1 ? .red : (weekday == 7 ? .blue : .primary)
        return inMonth ? base : base.opacity(0.3)
    }

    // MARK: selected-day events

    private var dayEvents: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(selectedDayTitle).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { editor = EventEditorTarget(existing: nil) } label: {
                    HStack(spacing: 3) { Image(systemName: "plus"); Text("追加") }.font(.system(size: 11, weight: .semibold))
                }.buttonStyle(.plain).foregroundColor(.blue)
            }
            let localItems = appState.events(on: selectedDay)
            let gcalItems  = gcal.events(on: selectedDay)
            let items = (localItems + gcalItems).sorted { $0.date < $1.date }
            if items.isEmpty {
                Text("この日の予定はありません").font(.system(size: 12)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                ForEach(items) { ev in eventRow(ev) }
            }
        }
    }

    private func eventRow(_ ev: ScheduleEvent) -> some View {
        let emp = appState.employees.first { $0.id == ev.assigneeId }
        let accent = emp?.role.color ?? .blue
        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(ev.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(ev.allDay ? "終日" : Self.timeFmt.string(from: Date(timeIntervalSince1970: ev.date)))
                        .foregroundColor(.secondary)
                    if let emp = emp {
                        Text("· \(emp.role.emoji) \(emp.name)").foregroundColor(accent)
                    }
                    if !ev.detail.isEmpty { Text("· \(ev.detail)").foregroundColor(.secondary).lineLimit(1) }
                }
                .font(.system(size: 10))
            }
            Spacer()
            Menu {
                Button { editor = EventEditorTarget(existing: ev) } label: { Label("編集", systemImage: "pencil") }
                Button(role: .destructive) { appState.deleteEvent(ev.id) } label: { Label("削除", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13)).foregroundColor(.secondary).frame(width: 24, height: 24)
            }.menuStyle(.borderlessButton).fixedSize()
        }
        .padding(10)
        .background(Color.primary.opacity(0.02)).cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture { editor = EventEditorTarget(existing: ev) }
    }

    // MARK: helpers

    private var monthDays: [Date?] {
        let start = Self.startOfMonth(month)
        guard let range = cal.range(of: .day, in: .month, for: start) else { return [] }
        let firstWeekday = cal.component(.weekday, from: start)  // 1=Sun
        let leading = firstWeekday - 1
        var cells: [Date?] = Array(repeating: nil, count: max(0, leading))
        for d in range {
            cells.append(cal.date(byAdding: .day, value: d - 1, to: start))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    private func shiftMonth(_ delta: Int) {
        if let m = cal.date(byAdding: .month, value: delta, to: month) { month = Self.startOfMonth(m) }
    }

    private var monthTitle: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "yyyy年 M月"
        return f.string(from: month)
    }
    private var selectedDayTitle: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "M月d日(E)"
        return f.string(from: selectedDay)
    }

    static func startOfMonth(_ d: Date) -> Date {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
    }
    static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "HH:mm"; return f
    }()
}

// MARK: - Event editor

struct EventEditorTarget: Identifiable {
    let id = UUID()
    let existing: ScheduleEvent?
}

struct EventEditSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    let existing: ScheduleEvent?
    let defaultDay: Date

    @State private var title = ""
    @State private var detail = ""
    @State private var date = Date()
    @State private var allDay = true
    @State private var assigneeId: String? = nil

    private var assigneeName: String {
        appState.employees.first { $0.id == assigneeId }.map { "\($0.role.emoji) \($0.name)" } ?? "なし"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "予定を追加" : "予定を編集").font(.system(size: 18, weight: .bold))

            VStack(alignment: .leading, spacing: 5) {
                Text("タイトル").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                TextField("例: 定例ミーティング", text: $title)
                    .textFieldStyle(.plain).padding(8)
                    .background(Color.primary.opacity(0.05)).cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
            }

            Toggle(isOn: $allDay) { Text("終日").font(.system(size: 12)) }
                .toggleStyle(.switch).controlSize(.small)

            DatePicker("日時", selection: $date,
                       displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                .datePickerStyle(.compact)
                .environment(\.locale, Locale(identifier: "ja_JP"))

            VStack(alignment: .leading, spacing: 5) {
                Text("担当社員（任意）").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                Menu {
                    Button { assigneeId = nil } label: { Label("なし", systemImage: assigneeId == nil ? "checkmark" : "minus") }
                    ForEach(appState.sortedEmployees) { e in
                        Button { assigneeId = e.id } label: {
                            Label("\(e.role.emoji) \(e.name)", systemImage: assigneeId == e.id ? "checkmark" : "")
                        }
                    }
                } label: {
                    HStack { Text(assigneeName).font(.system(size: 12)); Spacer(); Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)) }
                        .foregroundColor(.secondary).padding(8)
                        .background(Color.primary.opacity(0.05)).cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                }.menuStyle(.borderlessButton)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("メモ（任意）").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                TextField("詳細", text: $detail)
                    .textFieldStyle(.plain).padding(8)
                    .background(Color.primary.opacity(0.05)).cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
            }

            HStack {
                if existing != nil {
                    Button(role: .destructive) {
                        if let e = existing { appState.deleteEvent(e.id) }
                        dismiss()
                    } label: { Text("削除").font(.system(size: 12)) }.buttonStyle(.plain).foregroundColor(.red)
                }
                Spacer()
                Button("キャンセル") { dismiss() }.buttonStyle(.plain).foregroundColor(.secondary)
                Button(action: save) {
                    Text(existing == nil ? "追加" : "保存").font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(colorScheme == .dark ? Color.white : Color.black)
                        .foregroundColor(colorScheme == .dark ? .black : .white).cornerRadius(7)
                }.buttonStyle(.plain)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22).frame(width: 460)
        .onAppear {
            if let e = existing {
                title = e.title; detail = e.detail; allDay = e.allDay
                date = Date(timeIntervalSince1970: e.date); assigneeId = e.assigneeId
            } else {
                // default to the selected day (keep its date, default time 9:00 for timed events).
                let cal = Calendar.current
                date = cal.date(bySettingHour: 9, minute: 0, second: 0, of: defaultDay) ?? defaultDay
            }
        }
    }

    private func save() {
        let cal = Calendar.current
        let stamp = (allDay ? cal.startOfDay(for: date) : date).timeIntervalSince1970
        if let e = existing {
            appState.updateEvent(e.id, title: title, date: stamp, allDay: allDay, detail: detail, assigneeId: .some(assigneeId))
        } else {
            appState.addEvent(title: title, date: stamp, allDay: allDay, detail: detail, assigneeId: assigneeId)
        }
        dismiss()
    }
}
