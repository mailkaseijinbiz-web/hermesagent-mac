import SwiftUI
import Charts

/// Health metric dashboard shown in place of the empty "意図カードから選ぶか…" prompt when the
/// active employee is the 健康アドバイザー (see `Employee.isHealthAdvisor`). Surfaces trend
/// cards for the four metrics requested: 体重 / HbA1c / 心拍 / 歩数.
///
/// Data sources:
/// - 体重: `WeightRecordStore` (memo-parsed weight entries, synced from iOS).
/// - 心拍 / 歩数: `AppState.dailyHistory` (rolling daily rollup fed by iOS HealthKit pushes).
/// - HbA1c: `HbA1cRecordStore` — HealthKit has no standard quantity type for HbA1c (it's a
///   clinical lab value, not a sensor reading), so this is manually entered here via the
///   "＋" button and persisted locally like weight records.
struct HealthAdvisorDashboardView: View {
    @EnvironmentObject var appState: AppState

    @State private var showHbA1cEntry = false
    @State private var hba1cInput = ""

    private struct TrendPoint: Identifiable {
        let id = UUID()
        let date: Date
        let value: Double
    }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("健康ダッシュボード", systemImage: "heart.text.square.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.primary)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                weightCard
                hba1cCard
                heartRateCard
                stepsCard
            }
        }
        .frame(maxWidth: 640)
    }

    // MARK: 体重

    private var weightCard: some View {
        let records = WeightRecordStore.all().sorted { $0.recordedAt < $1.recordedAt }
        let points = records.suffix(14).map { TrendPoint(date: Date(timeIntervalSince1970: $0.recordedAt), value: $0.kg) }
        let latest = records.last?.kg ?? appState.latestHealth?.bodyMassKg
        return metricCard(title: "体重", icon: "scalemass.fill", color: .purple,
                           latest: latest.map { String(format: "%.1f", $0) }, unit: "kg", points: points)
    }

    // MARK: HbA1c

    private var hba1cCard: some View {
        let records = HbA1cRecordStore.all().sorted { $0.recordedAt < $1.recordedAt }
        let points = records.suffix(14).map { TrendPoint(date: Date(timeIntervalSince1970: $0.recordedAt), value: $0.percent) }
        let latest = records.last?.percent
        return metricCard(title: "HbA1c", icon: "drop.fill", color: .red,
                           latest: latest.map { String(format: "%.1f", $0) }, unit: "%", points: points) {
            Button { hba1cInput = ""; showHbA1cEntry = true } label: {
                Image(systemName: "plus.circle.fill").font(.system(size: 13)).foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showHbA1cEntry, arrowEdge: .bottom) { hba1cEntryPopover }
        }
    }

    private var hba1cEntryPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HbA1c を記録（検査値・%）").font(.system(size: 12, weight: .semibold))
            HStack(spacing: 6) {
                TextField("例: 5.8", text: $hba1cInput)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .padding(8).background(Color.primary.opacity(0.05)).cornerRadius(6)
                    .frame(width: 90)
                Text("%").font(.system(size: 12)).foregroundColor(.secondary)
            }
            Button {
                if let v = Double(hba1cInput.trimmingCharacters(in: .whitespaces)) {
                    HbA1cRecordStore.append(percent: v)
                }
                showHbA1cEntry = false
            } label: {
                Text("保存").font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Color.accentColor).foregroundColor(.white).cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(Double(hba1cInput.trimmingCharacters(in: .whitespaces)) == nil)
        }
        .padding(14).frame(width: 200)
    }

    // MARK: 心拍

    private var heartRateCard: some View {
        let days = recentDayRecords()
        let points = days.compactMap { d -> TrendPoint? in
            guard let v = d.restingHeartRate, let date = Self.dayFmt.date(from: d.date) else { return nil }
            return TrendPoint(date: date, value: Double(v))
        }
        let latest = appState.latestHealth?.restingHeartRate
            ?? appState.latestHealth?.heartRate
            ?? days.last(where: { $0.restingHeartRate != nil })?.restingHeartRate
        return metricCard(title: "心拍", icon: "heart.fill", color: .pink,
                           latest: latest.map { "\($0)" }, unit: "bpm", points: points)
    }

    // MARK: 歩数

    private var stepsCard: some View {
        let days = recentDayRecords()
        let points = days.compactMap { d -> TrendPoint? in
            guard let v = d.steps, let date = Self.dayFmt.date(from: d.date) else { return nil }
            return TrendPoint(date: date, value: Double(v))
        }
        let latest = days.last(where: { $0.steps != nil })?.steps ?? appState.latestHealth?.steps
        return metricCard(title: "歩数", icon: "figure.walk", color: .green,
                           latest: latest.map { "\($0)" }, unit: "歩", points: points)
    }

    private func recentDayRecords() -> [AppState.DayRecord] {
        Array(appState.dailyHistory.suffix(14))
    }

    // MARK: Card shell

    @ViewBuilder
    private func metricCard<T: View>(title: String, icon: String, color: Color,
                                      latest: String?, unit: String, points: [TrendPoint],
                                      @ViewBuilder trailing: () -> T = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                trailing()
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(latest ?? "—")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                if latest != nil {
                    Text(unit).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                }
            }
            if points.count >= 2 {
                Chart(points) { pt in
                    AreaMark(x: .value("日付", pt.date), y: .value("値", pt.value))
                        .foregroundStyle(LinearGradient(colors: [color.opacity(0.22), color.opacity(0)],
                                                         startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("日付", pt.date), y: .value("値", pt.value))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                        .interpolationMethod(.catmullRom)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 44)
            } else {
                Text("データなし")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.8))
                    .frame(height: 44, alignment: .center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
    }
}
