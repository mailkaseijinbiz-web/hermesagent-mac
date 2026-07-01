import XCTest
@testable import HermesCustom

@MainActor
final class CollectionStoreTests: XCTestCase {

    private var tempDir: URL!
    private var store: CollectionStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("collection-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let file = tempDir.appendingPathComponent("collection.json")
        let images = tempDir.appendingPathComponent("images", isDirectory: true)
        store = CollectionStore(fileURL: file, imageDir: images)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testEncodeDecodeRoundTrip() throws {
        let item = store.add(kind: "url", title: "Example", url: "https://example.com", source: "web")
        let data = try JSONEncoder().encode(store.items)
        let decoded = try JSONDecoder().decode([CollectionItem].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].id, item.id)
        XCTAssertEqual(decoded[0].title, "Example")
        XCTAssertEqual(decoded[0].url, "https://example.com")
    }

    func testDedupeSameURLWithin24Hours() {
        let first = store.add(kind: "url", title: "A", url: "https://dup.test/page")
        let second = store.add(kind: "url", title: "B", url: "https://dup.test/page")
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.items.count, 1)
    }

    func testCapAt500() {
        for i in 0..<510 {
            _ = store.add(kind: "text", text: "item \(i)")
        }
        XCTAssertEqual(store.items.count, 500)
        XCTAssertEqual(store.items.first?.text, "item 509")
        XCTAssertEqual(store.items.last?.text, "item 10")
    }

    func testDeleteRemovesItem() {
        let item = store.add(kind: "text", text: "delete me")
        XCTAssertEqual(store.items.count, 1)
        store.delete(id: item.id)
        XCTAssertTrue(store.items.isEmpty)
    }
}
