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

    func testListenBindAddressesLoopbackOnly() {
        XCTAssertEqual(NetworkPeerPolicy.listenBindAddresses(tailscaleIPv4: nil), ["127.0.0.1"])
        XCTAssertEqual(NetworkPeerPolicy.listenBindAddresses(tailscaleIPv4: ""), ["127.0.0.1"])
        XCTAssertEqual(NetworkPeerPolicy.listenBindAddresses(tailscaleIPv4: "   "), ["127.0.0.1"])
    }

    func testListenBindAddressesIncludesTailscale() {
        XCTAssertEqual(
            NetworkPeerPolicy.listenBindAddresses(tailscaleIPv4: "100.64.0.1"),
            ["127.0.0.1", "100.64.0.1"]
        )
        XCTAssertEqual(
            NetworkPeerPolicy.listenBindAddresses(tailscaleIPv4: "  100.127.255.1  "),
            ["127.0.0.1", "100.127.255.1"]
        )
    }

    func testListenBindAddressesIncludesLAN() {
        XCTAssertEqual(
            NetworkPeerPolicy.listenBindAddresses(tailscaleIPv4: nil, localLANIPv4: "192.168.1.5"),
            ["127.0.0.1", "192.168.1.5"]
        )
        XCTAssertEqual(
            NetworkPeerPolicy.listenBindAddresses(tailscaleIPv4: "100.64.0.1", localLANIPv4: "192.168.1.5"),
            ["127.0.0.1", "100.64.0.1", "192.168.1.5"]
        )
    }

    func testShouldRebindListenAddressesWhenTailscaleAppears() {
        XCTAssertTrue(NetworkPeerPolicy.shouldRebindListenAddresses(
            bound: ["127.0.0.1"],
            tailscaleIPv4: "100.64.0.1",
            localLANIPv4: nil
        ))
    }

    func testShouldNotRebindListenAddressesWhenUnchanged() {
        XCTAssertFalse(NetworkPeerPolicy.shouldRebindListenAddresses(
            bound: ["127.0.0.1", "100.64.0.1", "192.168.1.5"],
            tailscaleIPv4: "100.64.0.1",
            localLANIPv4: "192.168.1.5"
        ))
    }

    func testShouldRebindWhenTailscaleAppears() {
        XCTAssertTrue(NetworkPeerPolicy.shouldRebindTailscale(bound: nil, detected: "100.64.0.1"))
    }

    func testShouldRebindWhenTailscaleIPChanges() {
        XCTAssertTrue(NetworkPeerPolicy.shouldRebindTailscale(bound: "100.64.0.1", detected: "100.64.0.2"))
    }

    func testShouldNotRebindWhenUnchanged() {
        XCTAssertFalse(NetworkPeerPolicy.shouldRebindTailscale(bound: "100.64.0.1", detected: "100.64.0.1"))
        XCTAssertFalse(NetworkPeerPolicy.shouldRebindTailscale(bound: nil, detected: nil))
    }

    func testTailscaleIPv4RejectsCLIErrorText() {
        let err = "The Tailscale GUI failed to start: The operation couldn't be completed. (Tailscale.CLIError error 3.)"
        XCTAssertFalse(TailscaleIPv4.isTailscaleIPv4(err))
        XCTAssertFalse(TailscaleIPv4.isTailscaleIPv4("192.168.1.1"))
        XCTAssertTrue(TailscaleIPv4.isTailscaleIPv4("100.127.89.51"))
    }
}
