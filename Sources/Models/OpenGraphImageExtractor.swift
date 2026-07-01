import Foundation

enum OpenGraphImageExtractor {
    /// Pull og:image / twitter:image from HTML.
    static func extract(from html: String) -> String? {
        let patterns = [
            #"property="og:image" content="([^"]+)""#,
            #"property='og:image' content='([^']+)'"#,
            #"name="twitter:image" content="([^"]+)""#,
            #"content="([^"]+)" property="og:image""#,
        ]
        for pattern in patterns {
            if let url = firstMatch(in: html, pattern: pattern), isUsableImageURL(url) {
                return url
            }
        }
        return nil
    }

    static func fetchImageURL(from pageURL: String) async -> String? {
        guard let url = URL(string: pageURL),
              let html = await fetchHTML(url) else { return nil }
        return extract(from: html)
    }

    static func isUsableImageURL(_ urlString: String) -> Bool {
        guard urlString.hasPrefix("http") else { return false }
        let lower = urlString.lowercased()
        let blocked = [
            "ogp_default", "default.png", "default.jpg", "placeholder",
            "gnews/logo", "google_news_", "favicon", "s2/favicons",
            "j6_coFbogxhri9i", // Google News generic og:image
        ]
        return !blocked.contains(where: { lower.contains($0) })
    }

    private static func fetchHTML(_ url: URL) async -> String? {
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
