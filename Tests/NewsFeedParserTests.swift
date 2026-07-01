import XCTest
@testable import HermesCustom

final class NewsFeedParserTests: XCTestCase {

    func testSplitTitleExtractsSource() {
        let split = NewsFeedParser.splitTitle("新施設オープン - サウナイキタイ")
        XCTAssertEqual(split.title, "新施設オープン")
        XCTAssertEqual(split.source, "サウナイキタイ")
    }

    func testTopicsFromLikes() {
        XCTAssertEqual(NewsFeedParser.topics(from: ""), ["サウナ"])
        XCTAssertEqual(NewsFeedParser.topics(from: "サウナ, ランニング"), ["サウナ", "ランニング"])
    }

    func testParseRSSItem() {
        let xml = """
        <?xml version="1.0"?>
        <rss xmlns:media="http://search.yahoo.com/mrss/"><channel>
        <item>
          <title><![CDATA[テスト記事 - Example News]]></title>
          <link>https://example.com/a</link>
          <pubDate>Mon, 01 Jul 2026 06:00:00 GMT</pubDate>
          <source url="https://example.com">Example News</source>
          <media:thumbnail url="https://example.com/thumb.jpg"/>
        </item>
        </channel></rss>
        """
        let items = NewsFeedParser.parseGoogleNewsRSS(xml, topic: "サウナ", limit: 3)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "テスト記事")
        XCTAssertEqual(items[0].source, "Example News")
        XCTAssertEqual(items[0].sourceURL, "https://example.com")
        XCTAssertEqual(items[0].imageURL, "https://example.com/thumb.jpg")
        XCTAssertEqual(items[0].topic, "サウナ")
        XCTAssertFalse(items[0].date.isEmpty)
    }

    func testExtractImageFromDescription() {
        let html = "<a href=\"x\"><img src=\"https://cdn.example.com/p.jpg\" /></a>"
        XCTAssertEqual(
            NewsFeedParser.extractImageURL(from: html, itemXML: ""),
            "https://cdn.example.com/p.jpg"
        )
    }

    func testOpenGraphRejectsGenericImages() {
        XCTAssertFalse(OpenGraphImageExtractor.isUsableImageURL("https://s.yimg.jp/images/news-web/ogp_default.png"))
        XCTAssertTrue(OpenGraphImageExtractor.isUsableImageURL("https://cdn.example.com/article.jpg"))
    }

    func testMergeDedupesByLink() {
        let a = NewsFeedItem(title: "A", link: "https://x.com/1", date: "1h", source: "S", topic: "T")
        let b = NewsFeedItem(title: "A copy", link: "https://x.com/1", date: "2h", source: "S", topic: "T")
        let c = NewsFeedItem(title: "B", link: "https://x.com/2", date: "3h", source: "S", topic: "T")
        let merged = NewsFeedParser.merge([[a, b], [c]], max: 10)
        XCTAssertEqual(merged.count, 2)
    }
}
