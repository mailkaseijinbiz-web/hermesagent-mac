import SwiftUI
import AppKit

/// Renders a unified `DayTimelineEvent` row (Mac lifelog graph view).
struct DayTimelineRowView: View {
    let event: DayTimelineEvent
    let isLast: Bool
    var onEditMemo: ((String) -> Void)? = nil

    private let timeColWidth: CGFloat = 48
    private let railWidth: CGFloat = 14

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

    private var cardTint: Color? {
        switch event.kind {
        case "hermes": return Color.purple.opacity(0.06)
        default: return nil
        }
    }

    private var memoId: String? {
        guard event.kind == "memo", event.id.hasPrefix("memo-") else { return nil }
        return String(event.id.dropFirst(5))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(timeStr)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.65))
                .frame(width: timeColWidth, alignment: .trailing)
                .padding(.top, 4)

            VStack(spacing: 0) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 10, height: 10)
                    .padding(.top, 4)
                if !isLast {
                    Rectangle()
                        .fill(Color.primary.opacity(0.1))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                        .padding(.top, 4)
                }
            }
            .frame(width: railWidth)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundStyle(dotColor)
                    Text(event.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(dotColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(dotColor.opacity(0.12))
                        .clipShape(Capsule())
                    if event.sessionCount <= 1, let d = event.duration, d >= 60 {
                        Text(DayTimelineGraph.formatDuration(d))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if memoId != nil {
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
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                        .lineSpacing(3)
                        .lineLimit(event.sessionCount > 1 ? 2 : 6)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let names = event.imageNames, !names.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(names, id: \.self) { name in
                                memoThumbnail(name)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(cardTint ?? Color(.controlBackgroundColor).opacity(0.5))
            .cornerRadius(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, isLast ? 16 : 6)
    }

    @ViewBuilder
    private func memoThumbnail(_ name: String) -> some View {
        let url = MacMemoStore.imageURL(name)
        if let img = NSImage(contentsOf: url) {
            Image(nsImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 88, height: 88)
                .clipped()
                .cornerRadius(8)
        }
    }
}
