import XCTest
@testable import HermesCustom

final class MobileServerPeerTests: XCTestCase {

    func testLoopbackAllowed() {
        XCTAssertTrue(NetworkPeerPolicy.isTrustedPeerIP("127.0.0.1"))
        XCTAssertFalse(NetworkPeerPolicy.isPublicIPv4Peer("127.0.0.1"))
    }

    func testTailscaleAllowed() {
        for ip in ["100.64.0.1", "100.127.255.1"] {
            XCTAssertTrue(NetworkPeerPolicy.isTrustedPeerIP(ip), "expected trusted: \(ip)")
            XCTAssertFalse(NetworkPeerPolicy.isPublicIPv4Peer(ip), "expected not public: \(ip)")
        }
    }

    func testPrivateLANAllowed() {
        for ip in ["10.0.0.5", "192.168.1.1", "172.16.0.1"] {
            XCTAssertTrue(NetworkPeerPolicy.isTrustedPeerIP(ip), "expected trusted: \(ip)")
            XCTAssertFalse(NetworkPeerPolicy.isPublicIPv4Peer(ip), "expected not public: \(ip)")
        }
    }

    func testPublicIPv4Rejected() {
        XCTAssertFalse(NetworkPeerPolicy.isTrustedPeerIP("8.8.8.8"))
        XCTAssertTrue(NetworkPeerPolicy.isPublicIPv4Peer("8.8.8.8"))
    }
}
