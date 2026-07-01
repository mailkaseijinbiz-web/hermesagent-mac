import SwiftUI

/// Renders a unified `DayTimelineEvent` row (Mac lifelog graph view).
struct DayTimelineRowView: View {
    let event: DayTimelineEvent
    let isLast: Bool
    var onEditMemo: ((String) -> Void)? = nil

    private var timeStr: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: event.time))
    }

    private var icon: String {
        switch event.kind {
        case "hermes":   return "brain.head.profile"
        case "mac":      return "menubar.dock.rectangle"
        case "memo":
            switch event.label {
            case "共有リンク": return "link"
            case "写真": return "photo.fill"
            case "動画": return "video.fill"
            default: return "note.text"
            }
        case "health":   return "heart.fill"
        case "location": return "location.fill"
        case "photo":    return "photo.fill"
        default:         return "circle.fill"
        }
    }

    private var dotColor: Color {
        switch event.kind {
        case "hermes":   return .purple
        case "memo":     return .accentColor
        case "health":   return .green
        case "location": return .blue
        case "photo":    return .orange
        default:         return Color(.systemGray)
        }
    }

    private var memoId: String? {
        guard event.kind == "memo", event.id.hasPrefix("memo-") else { return nil }
        return String(event.id.dropFirst(5))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(timeStr)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
                .padding(.top, 3)

            VStack(spacing: 0) {
                Circle().fill(dotColor).frame(width: 8, height: 8).padding(.top, 5)
                if !isLast {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(dotColor)
                    Text(event.label)
                        .font(.system(size: 13, weight: .medium))
                    if event.sessionCount <= 1, let d = event.duration, d >= 60 {
                        Text(DayTimelineGraph.formatDuration(d))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if memoId != nil {
                        Spacer()
                        Button("編集") {
                            if let id = memoId { onEditMemo?(id) }
                        }
                        .font(.system(size: 11))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                if !event.detail.isEmpty && event.detail != event.label {
                    Text(event.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(event.sessionCount > 1 ? 1 : 3)
                }
            }
            .padding(.leading, 8)
            .padding(.bottom, 16)
        }
    }
}
