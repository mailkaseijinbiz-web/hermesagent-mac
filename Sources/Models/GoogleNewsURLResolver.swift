import Foundation

/// Resolves post-2024 Google News article URLs (`news.google.com/rss/articles/CBMi…`) to publisher URLs.
enum GoogleNewsURLResolver {
    private static let batchURL = URL(string: "https://news.google.com/_/DotsSplashUi/data/batchexecute")!
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

    static func isGoogleNewsArticleURL(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return host.contains("news.google.com") && urlString.contains("/articles/")
    }

    static func resolvePublisherURL(from googleNewsURL: String) async -> String? {
        guard isGoogleNewsArticleURL(googleNewsURL),
              let articleURL = URL(string: googleNewsURL) else { return nil }
        let articleID = articleURL.pathComponents.last?.split(separator: "?").first.map(String.init)
        guard let articleID, !articleID.isEmpty else { return nil }

        guard let pageHTML = await fetchHTML(articleURL) else { return nil }
        guard let signature = firstMatch(in: pageHTML, pattern: #"data-n-a-sg="([^"]+)""#),
              let timestampStr = firstMatch(in: pageHTML, pattern: #"data-n-a-ts="([^"]+)""#),
              let timestamp = Int(timestampStr) else { return nil }

        let rpcInner: [Any] = [
            "garturlreq",
            [
                ["X", "X", ["X", "X"], NSNull(), NSNull(), 1, 1, "US:en", NSNull(), 1,
                 NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), 0, 1],
                "X", "X", 1, [1, 1, 1], 1, 1, NSNull(), 0, 0, NSNull(), 0,
            ],
            articleID, timestamp, signature,
        ]
        guard let rpcData = try? JSONSerialization.data(withJSONObject: rpcInner, options: []),
              let rpcString = String(data: rpcData, encoding: .utf8) else { return nil }

        let fReqPayload: [[Any]] = [[["Fbv4je", rpcString, NSNull(), "generic"]]]
        guard let fReqData = try? JSONSerialization.data(withJSONObject: fReqPayload, options: []),
              let fReqString = String(data: fReqData, encoding: .utf8) else { return nil }

        var req = URLRequest(url: batchURL, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.setValue("https://news.google.com/", forHTTPHeaderField: "Referer")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = formBody(name: "f.req", value: fReqString)

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              var body = String(data: data, encoding: .utf8) else { return nil }

        if body.hasPrefix(")]}'") {
            body = String(body.split(separator: "\n", maxSplits: 1).last ?? Substring(body))
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstLine = body.split(separator: "\n", maxSplits: 1).first,
           firstLine.allSatisfy(\.isNumber),
           let rest = body.split(separator: "\n", maxSplits: 1).last {
            body = String(rest)
        }

        guard let envelopes = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [[Any]] else { return nil }
        for env in envelopes {
            guard env.count >= 3,
                  env[0] as? String == "wrb.fr",
                  env[1] as? String == "Fbv4je",
                  let inner = env[2] as? String,
                  let payload = try? JSONSerialization.jsonObject(with: Data(inner.utf8)) as? [Any],
                  payload.first as? String == "garturlres",
                  let resolved = payload.dropFirst().first as? String,
                  resolved.hasPrefix("http") else { continue }
            return resolved
        }
        return nil
    }

    private static func formBody(name: String, value: String) -> Data? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?")
        let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "\(name)=\(encoded)".data(using: .utf8)
    }

    private static func fetchHTML(_ url: URL) async -> String? {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
