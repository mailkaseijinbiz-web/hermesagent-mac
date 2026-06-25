import Foundation
import SwiftUI

struct ANSIConverter {
    // Strip ANSI escape codes from string
    static func cleanANSI(_ text: String) -> String {
        let pattern = "\\\u{001B}\\[[0-9;]*[a-zA-Z]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var cleaned = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        
        // Strip other common terminal graphics control characters
        cleaned = cleaned.replacingOccurrences(of: "\r", with: "")
        return cleaned
    }
    
    // Converts text into AttributedString (for style and color mapping)
    static func toAttributedString(_ text: String) -> AttributedString {
        let cleaned = cleanANSI(text)
        var attrString = AttributedString(cleaned)
        
        // Default text styles
        attrString.foregroundColor = .textColor
        
        return attrString
    }
}

// SwiftUI Color extension for fallback consistency
extension Color {
    static let textColor = Color(NSColor.labelColor)
}
