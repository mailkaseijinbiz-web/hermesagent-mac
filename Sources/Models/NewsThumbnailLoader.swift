import AppKit
import Foundation
import LinkPresentation

/// Loads news row thumbnails: RSS image → publisher og:image → LinkPresentation preview.
enum NewsThumbnailLoader {
    private static let cache = NSCache<NSString, NSImage>()

    static func load(for item: NewsFeedItem) async -> NSImage? {
        let key = (item.imageURL ?? item.link) as NSString
        if let cached = cache.object(forKey: key) { return cached }

        if let urlStr = item.imageURL, OpenGraphImageExtractor.isUsableImageURL(urlStr),
           let url = URL(string: urlStr), let img = await download(url), isPhotoSized(img) {
            cache.setObject(img, forKey: key)
            return img
        }

        let articleURL = await resolvedArticleURL(for: item)
        if let ogURL = await OpenGraphImageExtractor.fetchImageURL(from: articleURL),
           let url = URL(string: ogURL), let img = await download(url), isPhotoSized(img) {
            cache.setObject(img, forKey: key)
            return img
        }

        if let url = URL(string: articleURL),
           let img = await linkPreviewImage(for: url), isPhotoSized(img) {
            cache.setObject(img, forKey: key)
            return img
        }

        return nil
    }

    static func faviconDomain(from sourceURL: String?) -> String? {
        guard let sourceURL, let host = URL(string: sourceURL)?.host, !host.isEmpty else { return nil }
        return host
    }

    private static func resolvedArticleURL(for item: NewsFeedItem) async -> String {
        if GoogleNewsURLResolver.isGoogleNewsArticleURL(item.link),
           let resolved = await GoogleNewsURLResolver.resolvePublisherURL(from: item.link) {
            return resolved
        }
        return item.link
    }

    private static func isPhotoSized(_ img: NSImage) -> Bool {
        let size = img.size
        return size.width >= 80 && size.height >= 80
    }

    private static func download(_ url: URL) async -> NSImage? {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let img = NSImage(data: data) else { return nil }
        return img
    }

    private static func linkPreviewImage(for url: URL) async -> NSImage? {
        await withCheckedContinuation { cont in
            LPMetadataProvider().startFetchingMetadata(for: url) { meta, _ in
                guard let provider = meta?.imageProvider else {
                    cont.resume(returning: nil)
                    return
                }
                provider.loadObject(ofClass: NSImage.self) { obj, _ in
                    cont.resume(returning: obj as? NSImage)
                }
            }
        }
    }
}
