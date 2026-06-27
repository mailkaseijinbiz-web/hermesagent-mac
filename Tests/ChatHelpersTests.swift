import XCTest
@testable import HermesCustom

/// Pure-logic helpers added for the file-chip rendering and the delivery-target picker.
final class ChatHelpersTests: XCTestCase {

    // MARK: - MessageBlock.fileLinks

    func testFileLinksExtractsNameAndDecodedPath() {
        let s = "作成: [plan.md](file:///Users/k/Capfan%E9%96%8B%E7%99%BA/plan.md) 完了"
        let links = MessageBlock.fileLinks(s)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.name, "plan.md")
        // %E9%96%8B%E7%99%BA → 開発
        XCTAssertEqual(links.first?.path, "/Users/k/Capfan開発/plan.md")
    }

    func testFileLinksDedupesSamePath() {
        let s = "[a](file:///t/x.md) と [b](file:///t/x.md)"
        XCTAssertEqual(MessageBlock.fileLinks(s).count, 1)
    }

    func testFileLinksIgnoresNonFileLinks() {
        let s = "[Google](https://google.com) と ただの file という単語"
        XCTAssertTrue(MessageBlock.fileLinks(s).isEmpty)
    }

    func testFileLinksHandlesMultiple() {
        let s = "[a.txt](file:///t/a.txt)\n[b.txt](file:///t/b.txt)"
        let links = MessageBlock.fileLinks(s)
        XCTAssertEqual(links.map { $0.name }, ["a.txt", "b.txt"])
    }

    // MARK: - MessageBlock.stripFileLinks

    func testStripFileLinksReplacesWithName() {
        let s = "保存: [plan.md](file:///t/plan.md) しました"
        XCTAssertEqual(MessageBlock.stripFileLinks(s), "保存: plan.md しました")
    }

    func testStripFileLinksLeavesNonFileLinks() {
        let s = "[Google](https://google.com)"
        XCTAssertEqual(MessageBlock.stripFileLinks(s), s)
    }

    // MARK: - DeliverPicker.channelMenuLabel

    func testChannelMenuLabelShortensLongLineId() {
        let ch = HermesChannel(platform: "line",
                               channelId: "U752e3d6440ab40545735d1a1e0246584",
                               name: "U752e3d6440ab40545735d1a1e0246584",
                               type: "dm")
        let label = DeliverPicker.channelMenuLabel(ch)
        XCTAssertTrue(label.hasPrefix("LINE"))
        XCTAssertTrue(label.contains("246584"))            // 末尾6桁を表示
        XCTAssertFalse(label.contains("U752e3d6440ab"))    // 全長は出さない
    }

    func testChannelMenuLabelUsesNameWhenNamed() {
        let ch = HermesChannel(platform: "telegram", channelId: "12345", name: "Keita", type: "dm")
        XCTAssertEqual(DeliverPicker.channelMenuLabel(ch), "TELEGRAM：Keita")
    }
}
