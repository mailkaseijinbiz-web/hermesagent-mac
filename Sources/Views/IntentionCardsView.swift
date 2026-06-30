import SwiftUI

/// Intention cards — surfaces AI/hybrid hypotheses; tap to act, swipe/context to dismiss.
struct IntentionCardsView: View {
    let vitalHint: String
    let vitalityMode: String
    let cards: [IntentionCard]
    let isGenerating: Bool
    let isSilent: Bool
    var onConfirm: (IntentionCard) -> Void
    var onDismiss: (IntentionCard) -> Void
    var onRegenerate: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if !vitalityMode.isEmpty { VitalityModeBadge(mode: vitalityMode) }
                if !vitalHint.isEmpty {
                    Text(vitalHint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if cards.isEmpty {
                if isGenerating {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("文脈を読み取っています…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                } else if isSilent {
                    Text("今日は静かに過ごすのも正解です。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Text("まだ意図がありません。更新してください。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(cards) { card in
                        IntentionCardRow(card: card, onTap: { onConfirm(card) }, onDismiss: { onDismiss(card) })
                    }
                }
            }
        }
    }
}

private struct IntentionCardRow: View {
    let card: IntentionCard
    let onTap: () -> Void
    let onDismiss: () -> Void

    private var accent: Color {
        switch card.kind {
        case "recover": return .green
        case "rest":    return .indigo
        case "explore": return .orange
        case "task":    return .blue
        default:       return .accentColor
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: card.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 28, height: 28)
                .background(accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .font(.system(size: 14, weight: .semibold))
                Text(card.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.15), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: onTap)
    }
}

#if os(macOS)
extension IntentionCardsView {
    /// Dashboard widget wrapper (Mac) — outer `card()` supplies the title.
    static func dashboardWidget(appState: AppState) -> some View {
        IntentionCardsView(
            vitalHint: appState.intentionVitalHint,
            vitalityMode: appState.intentionVitalityMode,
            cards: appState.visibleIntentionCards,
            isGenerating: appState.isGeneratingIntention,
            isSilent: appState.intentionIsSilent,
            onConfirm: { card in _ = appState.confirmIntentionCard(card.id) },
            onDismiss: { card in appState.dismissIntentionCard(card.id) },
            onRegenerate: nil
        )
    }
}
#endif
