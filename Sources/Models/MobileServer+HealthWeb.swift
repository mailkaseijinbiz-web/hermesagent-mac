import Foundation
import Network

// 健康ダッシュボードのWeb切り出し（GET /health = HTML、GET /api/health/dashboard = JSON）。
// Tailscale内のブラウザ（iPhone/iPad/他PC）から閲覧する読み取り専用ビュー。
extension MobileServer {

    nonisolated func handleHealthDashboardJSON(connection: NWConnection, corsHeaders: String) {
        Task { @MainActor in
            let s = AppState.shared
            let hist = s.dailyHistory.suffix(60)
            let weight = hist.compactMap { d in d.bodyMassKg.map { ["date": d.date, "v": $0] as [String: Any] } }
            let heart  = hist.compactMap { d in d.restingHeartRate.map { ["date": d.date, "v": $0] as [String: Any] } }
            let steps  = hist.compactMap { d in d.steps.map { ["date": d.date, "v": $0] as [String: Any] } }
            let hba1c  = HbA1cRecordStore.all()
                .sorted { $0.recordedAt < $1.recordedAt }
                .map { r -> [String: Any] in
                    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
                    return ["date": f.string(from: Date(timeIntervalSince1970: r.recordedAt)), "v": r.percent]
                }
            var latest: [String: Any] = [:]
            if let h = s.latestHealth {
                latest["steps"] = h.steps ?? NSNull()
                latest["heart"] = h.restingHeartRate ?? NSNull()
            }
            if latest["steps"] == nil || latest["steps"] is NSNull,
               let sv = steps.last?["v"] { latest["steps"] = sv }
            if latest["heart"] == nil || latest["heart"] is NSNull,
               let hv = heart.last?["v"] { latest["heart"] = hv }
            if let w = weight.last?["v"] { latest["weight"] = w }
            if let a = hba1c.last?["v"] { latest["hba1c"] = a }
            if let wp = WeightProgress.line(history: Array(s.dailyHistory)) { latest["weightLine"] = wp }
            self.sendJSON(connection: connection, [
                "weight": weight, "heart": heart, "steps": steps, "hba1c": hba1c, "latest": latest
            ], corsHeaders: corsHeaders)
        }
    }

    nonisolated func handleHealthWebPage(connection: NWConnection, corsHeaders: String) {
        let html = Self.healthDashboardHTML
        let data = Data(html.utf8)
        var header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(data.count)\r\n\(corsHeaders)\r\nConnection: close\r\n\r\n"
        header += ""
        var payload = Data(header.utf8)
        payload.append(data)
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    // 自己完結HTML（外部CDNなし・SVGスパークライン手描き・60秒自動更新）
    static let healthDashboardHTML = #"""
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>健康ダッシュボード</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; margin: 0; }
  body { background: #0b0b0d; color: #f2f2f4; font-family: -apple-system, "Hiragino Sans", sans-serif; padding: 20px; }
  h1 { font-size: 18px; margin-bottom: 16px; display: flex; align-items: center; gap: 8px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 14px; max-width: 1100px; margin: 0 auto; }
  .card { background: #161618; border-radius: 16px; padding: 18px 20px; min-height: 170px; }
  .label { font-size: 13px; color: #9a9aa0; display: flex; align-items: center; gap: 6px; margin-bottom: 8px; }
  .value { font-size: 34px; font-weight: 700; letter-spacing: -0.5px; }
  .unit { font-size: 14px; color: #9a9aa0; font-weight: 500; margin-left: 3px; }
  .sub { font-size: 12px; color: #7a7a80; margin-top: 6px; }
  .nodata { color: #6a6a70; font-size: 13px; text-align: center; padding: 28px 0; }
  svg { width: 100%; height: 74px; margin-top: 10px; display: block; }
  .updated { text-align: center; color: #55555c; font-size: 11px; margin-top: 18px; }
</style>
</head>
<body>
<h1>🩺 健康ダッシュボード</h1>
<div class="grid" id="grid">読み込み中…</div>
<div class="updated" id="updated"></div>
<script>
const KEY = new URLSearchParams(location.search).get("key") || "";

function spark(points, color) {
  if (!points || points.length < 2) return '<div class="nodata">データなし</div>';
  const vs = points.map(p => p.v);
  const min = Math.min(...vs), max = Math.max(...vs);
  const range = (max - min) || 1;
  const W = 300, H = 70, PAD = 4;
  const xs = points.map((p, i) => PAD + i * (W - 2 * PAD) / (points.length - 1));
  const ys = points.map(p => H - PAD - (p.v - min) / range * (H - 2 * PAD));
  const d = xs.map((x, i) => (i ? "L" : "M") + x.toFixed(1) + "," + ys[i].toFixed(1)).join(" ");
  const fill = d + ` L${xs[xs.length-1].toFixed(1)},${H} L${xs[0].toFixed(1)},${H} Z`;
  return `<svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none">
    <path d="${fill}" fill="${color}" opacity="0.14"/>
    <path d="${d}" fill="none" stroke="${color}" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>
  </svg>`;
}

function card(icon, label, value, unit, points, color, sub) {
  const v = (value === null || value === undefined)
    ? '<span style="color:#6a6a70">—</span>'
    : `${value}<span class="unit">${unit}</span>`;
  return `<div class="card"><div class="label">${icon} ${label}</div>
    <div class="value">${v}</div>${spark(points, color)}${sub ? `<div class="sub">${sub}</div>` : ""}</div>`;
}

async function load() {
  try {
    const r = await fetch("/api/health/dashboard", { headers: { Authorization: "Bearer " + KEY } });
    if (!r.ok) throw new Error("HTTP " + r.status);
    const d = await r.json();
    const L = d.latest || {};
    document.getElementById("grid").innerHTML =
      card("⚖️", "体重", L.weight != null ? Number(L.weight).toFixed(1) : null, "kg", d.weight, "#5ac8fa", L.weightLine || "") +
      card("🩸", "HbA1c", L.hba1c != null ? Number(L.hba1c).toFixed(1) : null, "%", d.hba1c, "#ff9f0a", "追加はMacアプリから") +
      card("❤️", "安静時心拍", L.heart ?? null, "bpm", d.heart, "#ff375f", "") +
      card("👟", "歩数（今日）", L.steps != null ? Number(L.steps).toLocaleString() : null, "歩", d.steps, "#30d158", "直近60日の推移");
    document.getElementById("updated").textContent =
      "更新 " + new Date().toLocaleTimeString("ja-JP", { hour: "2-digit", minute: "2-digit" }) + "（60秒ごと自動更新）";
  } catch (e) {
    document.getElementById("grid").innerHTML = `<div class="card"><div class="nodata">取得エラー: ${e.message}<br>URLの key= を確認してください</div></div>`;
  }
}
load();
setInterval(load, 60000);
</script>
</body>
</html>
"""#
}
