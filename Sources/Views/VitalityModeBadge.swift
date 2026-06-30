import SwiftUI

/// Vitality mode chip shown above intention cards.
struct VitalityModeBadge: View {
    let mode: String

    private var label: String {
        switch mode {
        case "depleted":   return "消耗気味"
        case "recovering": return "回復"
        case "peak":       return "集中向き"
        default:           return "安定"
        }
    }

    private var color: Color {
        switch mode {
        case "depleted":   return .orange
        case "recovering": return .green
        case "peak":       return .purple
        default:           return .blue
        }
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}
