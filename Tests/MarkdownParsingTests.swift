import XCTest
@testable import HermesCustom

/// Regression tests for the pure chat-rendering logic: markdown block parsing,
/// GFM table extraction, fenced-code segmentation, ANSI cleanup, and the UTF-8
/// stream buffer that fixes multi-byte chunk-split character loss.
final class MarkdownParsingTests: XCTestCase {

    // MARK: - Block parsing

    func testHeadingBulletOrderedQuoteParagraph() {
        let blocks = MessageBlock.blocks("""
        # 見出し
        本文の段落です。

        - 箇条書き1
        - 箇条書き2
        1. 番号1
        > 引用です
        """)
        guard case .heading(let level, let h) = blocks[0] else { return XCTFail("expected heading, got \(blocks[0])") }
        XCTAssertEqual(level, 1)
        XCTAssertEqual(h, "見出し")
        XCTAssertTrue(blocks.contains { if case .paragraph(let p) = $0 { return p == "本文の段落です。" }; return false })
        XCTAssertTrue(blocks.contains { if case .bullet(let b) = $0 { return b == "箇条書き1" }; return false })
        XCTAssertTrue(blocks.contains { if case .ordered(let m, let t) = $0 { return m == "1." && t == "番号1" }; return false })
        XCTAssertTrue(blocks.contains { if case .quote(let q) = $0 { return q == "引用です" }; return false })
    }

    func testGFMTableExtraction() {
        let blocks = MessageBlock.blocks("""
        | 手順 | 内容 |
        |------|------|
        | ① 確認 | ブリッジを起動 |
        | ② 送信 | LINEへ通知 |
        """)
        guard let table = blocks.compactMap({ block -> ([String], [[String]])? in
            if case .table(let header, let rows) = block { return (header, rows) }
            return nil
        }).first else { return XCTFail("expected a table block, got \(blocks)") }
        XCTAssertEqual(table.0, ["手順", "内容"])
        XCTAssertEqual(table.1.count, 2)
        XCTAssertEqual(table.1[0], ["① 確認", "ブリッジを起動"])
        XCTAssertEqual(table.1[1], ["② 送信", "LINEへ通知"])
    }

    func testTableDelimiterDetection() {
        XCTAssertTrue(MessageBlock.isTableDelimiter("|---|---|"))
        XCTAssertTrue(MessageBlock.isTableDelimiter("| :--- | ---: |"))
        XCTAssertFalse(MessageBlock.isTableDelimiter("| a | b |"))   // no dashes → not a delimiter
        XCTAssertFalse(MessageBlock.isTableDelimiter("just text"))
    }

    // MARK: - Fenced code segmentation

    func testFencedCodeSplit() {
        let segs = MessageBlock.segments("""
        前置き
        ```bash
        hermes line-bridge start
        ```
        後書き
        """)
        XCTAssertEqual(segs.count, 3)
        if case .text(let t) = segs[0] { XCTAssertEqual(t.trimmingCharacters(in: .whitespacesAndNewlines), "前置き") } else { XCTFail() }
        if case .code(let lang, let body) = segs[1] {
            XCTAssertEqual(lang, "bash")
            XCTAssertEqual(body, "hermes line-bridge start")
        } else { XCTFail("expected code segment") }
        if case .text(let t) = segs[2] { XCTAssertEqual(t.trimmingCharacters(in: .whitespacesAndNewlines), "後書き") } else { XCTFail() }
    }

    func testPlainTextIsSingleSegment() {
        let segs = MessageBlock.segments("コードを含まない普通の文章。")
        XCTAssertEqual(segs.count, 1)
        if case .text = segs[0] {} else { XCTFail("expected a single text segment") }
    }

    // MARK: - ANSI cleanup

    func testCleanStripsANSI() {
        let coloured = "\u{1B}[31mエラー\u{1B}[0m"
        XCTAssertEqual(AntigravityCLI.clean(coloured), "エラー")
    }

    // MARK: - UTF-8 stream buffer (multi-byte chunk-split safety)

    func testUTF8BufferReassemblesSplitCharacter() {
        // "あ" = E3 81 82; split across two reads.
        let buf = UTF8StreamBuffer()
        XCTAssertNil(buf.append(Data([0xE3, 0x81])), "incomplete sequence must be held, not emitted")
        XCTAssertEqual(buf.append(Data([0x82])), "あ")
    }

    func testUTF8BufferMultiCharSplit() {
        // "日本" = E6 97 A5 E6 9C AC; split mid second char. A trailing partial byte
        // holds the whole buffer until it decodes cleanly (then emits together) — the
        // key property is that no bytes are dropped.
        let buf = UTF8StreamBuffer()
        XCTAssertNil(buf.append(Data([0xE6, 0x97, 0xA5, 0xE6])))   // 日 + partial 本 → held
        XCTAssertEqual(buf.append(Data([0x9C, 0xAC])), "日本")
    }

    func testUTF8BufferFlushEmitsRemainder() {
        let buf = UTF8StreamBuffer()
        XCTAssertNil(buf.append(Data([0xE3, 0x81])))            // partial "あ"
        XCTAssertEqual(buf.flush(Data([0x82])), "あ")           // completed at EOF
    }
}
