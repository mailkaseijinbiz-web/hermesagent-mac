import SwiftUI
import Charts

// MARK: - Chart data model

struct ChartDataPoint: Identifiable {
    let id = UUID()
    let label: String
    let value: Double
    let series: String
}

struct ChartSpec {
    var type: String = "bar"    // "bar" | "line" | "area" | "pie"
    var title: String = ""
    var xLabel: String = ""
    var yLabel: String = ""
    var points: [ChartDataPoint] = []
    var hasMultipleSeries: Bool { Set(points.map(\.series)).filter { !$0.isEmpty }.count > 1 }

    /// Parse JSON chart spec. `langHint` = "chart-bar" style lang tag override.
    static func parse(json: String, langHint: String = "") -> ChartSpec? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var spec = ChartSpec()
        let typeFromLang = langHint.hasPrefix("chart-") ? String(langHint.dropFirst("chart-".count)) : ""
        spec.type   = typeFromLang.isEmpty ? (obj["type"] as? String ?? "bar") : typeFromLang
        spec.title  = obj["title"]  as? String ?? ""
        spec.xLabel = obj["xLabel"] as? String ?? obj["x_label"] as? String ?? ""
        spec.yLabel = obj["yLabel"] as? String ?? obj["y_label"] as? String ?? ""

        func toDouble(_ d: [String: Any]) -> Double? {
            if let v = d["value"] as? Double { return v }
            if let v = d["value"] as? Int    { return Double(v) }
            if let v = d["y"]     as? Double { return v }
            if let v = d["y"]     as? Int    { return Double(v) }
            return nil
        }
        func labelOf(_ d: [String: Any]) -> String {
            d["label"] as? String ?? d["x"] as? String ?? d["name"] as? String ?? ""
        }

        // Single series: { data: [{label, value}] }
        if let arr = obj["data"] as? [[String: Any]] {
            spec.points = arr.compactMap { d in
                guard let v = toDouble(d) else { return nil }
                return ChartDataPoint(label: labelOf(d), value: v, series: "")
            }
        }
        // Multi series: { series: [{name, data: [{label, value}]}] }
        if let seriesArr = obj["series"] as? [[String: Any]], !seriesArr.isEmpty {
            spec.points = seriesArr.flatMap { s -> [ChartDataPoint] in
                let name = s["name"] as? String ?? ""
                let vals = s["data"] as? [[String: Any]] ?? s["values"] as? [[String: Any]] ?? []
                return vals.compactMap { d in
                    guard let v = toDouble(d) else { return nil }
                    return ChartDataPoint(label: labelOf(d), value: v, series: name)
                }
            }
        }

        return spec.points.isEmpty ? nil : spec
    }
}

// MARK: - View

struct ChartBlockView: View {
    let language: String
    let json: String
    @State private var showRaw = false
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        if let spec = ChartSpec.parse(json: json, langHint: language) {
            VStack(alignment: .leading, spacing: 10) {
                if !spec.title.isEmpty {
                    Text(spec.title)
                        .font(.system(size: 13, weight: .semibold))
                }
                chartContent(spec)
                    .frame(height: spec.type == "pie" ? 200 : 220)
                if !spec.xLabel.isEmpty || !spec.yLabel.isEmpty {
                    HStack {
                        Text(spec.yLabel).font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        Text(spec.xLabel).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Button { showRaw.toggle() } label: {
                    Label(showRaw ? "グラフを表示" : "データを表示",
                          systemImage: showRaw ? "chart.bar.fill" : "tablecells")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                if showRaw { CodeBlockView(language: "json", code: json) }
            }
            .padding(14)
            .background(Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.02))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
        } else {
            // Parse failure → fall back to raw JSON code block
            CodeBlockView(language: "json", code: json)
        }
    }

    @ViewBuilder
    private func chartContent(_ spec: ChartSpec) -> some View {
        switch spec.type {
        case "line":
            Chart(spec.points) { pt in
                LineMark(
                    x: .value("ラベル", pt.label),
                    y: .value("値", pt.value)
                )
                .foregroundStyle(by: .value("系列", spec.hasMultipleSeries ? pt.series : "値"))
                PointMark(
                    x: .value("ラベル", pt.label),
                    y: .value("値", pt.value)
                )
                .foregroundStyle(by: .value("系列", spec.hasMultipleSeries ? pt.series : "値"))
                .symbolSize(40)
            }
            .chartLegend(spec.hasMultipleSeries ? .visible : .hidden)

        case "area":
            Chart(spec.points) { pt in
                AreaMark(
                    x: .value("ラベル", pt.label),
                    y: .value("値", pt.value)
                )
                .foregroundStyle(by: .value("系列", spec.hasMultipleSeries ? pt.series : "値"))
                .opacity(0.35)
                LineMark(
                    x: .value("ラベル", pt.label),
                    y: .value("値", pt.value)
                )
                .foregroundStyle(by: .value("系列", spec.hasMultipleSeries ? pt.series : "値"))
            }
            .chartLegend(spec.hasMultipleSeries ? .visible : .hidden)

        case "pie":
            Chart(spec.points) { pt in
                SectorMark(
                    angle:        .value("値", pt.value),
                    innerRadius:  .ratio(0.55),
                    angularInset: 1.5
                )
                .foregroundStyle(by: .value("ラベル", pt.label))
                .cornerRadius(3)
            }
            .chartLegend(.visible)

        default: // "bar"
            Chart(spec.points) { pt in
                BarMark(
                    x: .value("ラベル", pt.label),
                    y: .value("値", pt.value)
                )
                .foregroundStyle(by: .value("系列", spec.hasMultipleSeries ? pt.series : "値"))
            }
            .chartLegend(spec.hasMultipleSeries ? .visible : .hidden)
        }
    }
}
