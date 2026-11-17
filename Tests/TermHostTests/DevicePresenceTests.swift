import XCTest
@testable import TermHost

final class DevicePresenceTests: XCTestCase {
    private func session(_ devices: [ClientDevice]?, kinds: [String]? = nil, origin: String? = nil, originName: String? = nil) -> SessionInfo {
        var s = SessionInfo(id: "a", name: "1", command: "claude", cwd: "/x", created: 0, clients: devices?.count ?? kinds?.count ?? 0)
        s.clientDevices = devices
        s.clientKinds = kinds
        s.origin = origin
        s.originName = originName
        return s
    }

    func testNamedPhoneOnAMacRow() {
        let s = session([ClientDevice(kind: "iphone", name: "Alex's iPhone 13 Pro")])
        let others = DevicePresence.others(s, ownKind: "mac", ownName: "Alex's MacBook Pro", attachedHere: false)
        XCTAssertEqual(DevicePresence.connectedLabel(others), "Alex's iPhone 13 Pro connected")
        XCTAssertEqual(DevicePresence.symbol(others), "iphone")
    }

    func testThisAppIsLeftOutWhenItHasTheSessionOpen() {
        let s = session([ClientDevice(kind: "mac", name: "Alex's MacBook Pro"), ClientDevice(kind: "iphone", name: "Alex's iPhone")])
        let others = DevicePresence.others(s, ownKind: "mac", ownName: "Alex's MacBook Pro", attachedHere: true)
        XCTAssertEqual(others, [ClientDevice(kind: "iphone", name: "Alex's iPhone")])
        let two = session([ClientDevice(kind: "mac", name: "Studio"), ClientDevice(kind: "mac", name: "Alex's MacBook Pro")])
        XCTAssertEqual(DevicePresence.others(two, ownKind: "mac", ownName: "Alex's MacBook Pro", attachedHere: true),
                       [ClientDevice(kind: "mac", name: "Studio")])
    }

    func testSeveralDevicesAndUnknownOnes() {
        XCTAssertEqual(DevicePresence.connectedLabel([ClientDevice(kind: "iphone", name: "A"), ClientDevice(kind: "mac", name: "B")]), "A, B connected")
        XCTAssertEqual(DevicePresence.connectedLabel([ClientDevice(kind: "iphone", name: "A"), ClientDevice(kind: "mac", name: "B"),
                                                      ClientDevice(kind: "other")]), "A and 2 others connected")
        XCTAssertEqual(DevicePresence.connectedLabel([ClientDevice(kind: "other")]), "another device connected")
        XCTAssertEqual(DevicePresence.connectedLabel([ClientDevice(kind: "iphone")]), "an iPhone connected")
        XCTAssertNil(DevicePresence.connectedLabel([]))
        XCTAssertEqual(DevicePresence.symbol([ClientDevice(kind: "iphone"), ClientDevice(kind: "mac")]), "laptopcomputer.and.iphone")
    }

    func testOlderServiceWithKindsOnly() {
        let s = session(nil, kinds: ["iphone"])
        XCTAssertEqual(DevicePresence.connectedLabel(DevicePresence.others(s, ownKind: "mac", ownName: "M", attachedHere: false)),
                       "an iPhone connected")
    }

    func testOrigin() {
        XCTAssertEqual(DevicePresence.originLabel(session(nil, origin: "iphone", originName: "Alex's iPhone 13 Pro")), "from Alex's iPhone 13 Pro")
        XCTAssertEqual(DevicePresence.originLabel(session(nil, origin: "iphone")), "from iPhone")
        XCTAssertNil(DevicePresence.originLabel(session(nil, origin: "cli")))
    }

    func testModelNames() {
        XCTAssertEqual(DevicePresence.iPhoneModelName("iPhone14,2"), "iPhone 13 Pro")
        XCTAssertEqual(DevicePresence.iPhoneModelName("iPhone17,1"), "iPhone 16 Pro")
        XCTAssertEqual(DevicePresence.iPhoneModelName("iPhone99,9"), "iPhone")
        XCTAssertTrue(DevicePresence.isGenericDeviceName("iPhone"))
        XCTAssertFalse(DevicePresence.isGenericDeviceName("Alex's iPhone"))
    }

    func testRoles() {
        XCTAssertEqual(MachineRole.clean("  Agents "), "Agents")
        XCTAssertNil(MachineRole.clean("   "))
        XCTAssertNil(MachineRole.clean(nil))
    }
}
