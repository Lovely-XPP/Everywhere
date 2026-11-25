import Foundation
@testable import MacHost
import RemoteControl
import XCTest

/// 模拟系统守护进程的 plist 回执，覆盖线缆筛选与 USB 端口连接格式。
final class USBPacketTests: XCTestCase {
    private func plist(_ fields: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: fields, format: .xml, options: 0)
    }

    func testListSelectsOnlyUniqueWiredSerial() throws {
        func entry(_ type: String, _ serial: String, _ id: Int) -> [String: Any] {
            ["DeviceID": id, "Properties": ["ConnectionType": type, "SerialNumber": serial]]
        }
        let wired = entry("USB", "ABC-123", 7)
        let wireless = entry("Network", "ABC-123", 8)
        let other = entry("USB", "ABC-456", 9)
        let data = try plist(["DeviceList": [other, wireless, wired]])
        XCTAssertEqual(try MuxPacket.usbNumber(in: data, for: "abc123"), 7)
        for list in [[wireless], [other], [wired, wired]] {
            XCTAssertThrowsError(try MuxPacket.usbNumber(in: plist(["DeviceList": list]), for: "abc123")) {
                XCTAssertTrue($0 is MuxPacket.MissingCable)
            }
        }
    }

    func testNetworkAddressMatchesOnlyNetworkRecords() throws {
        let ip = try XCTUnwrap(WirelessDeviceAddress.bytes("192.168.1.25"))
        let addr = Data([16, 2, 0, 0]) + ip + Data(repeating: 0, count: 8)
        func entry(_ type: String, _ id: String) -> [String: Any] {
            ["Properties": ["ConnectionType": type, "SerialNumber": id, "NetworkAddress": addr]]
        }
        let data = try plist(["DeviceList": [entry("USB", "cable"), entry("Network", "wifi")]])
        XCTAssertEqual(try WirelessDeviceAddress.networkIDs(in: data, address: ip), ["wifi"])
        XCTAssertTrue(try WirelessDeviceAddress.networkIDs(in: data, address: Data([1,2,3,4])).isEmpty)
        XCTAssertNil(WirelessDeviceAddress.bytes("not-an-ip"))
    }

    func testConnectHeaderAndResult() throws {
        let frame = try MuxPacket.connectRequest(to: 7)
        let header = frame.prefix(16)
        XCTAssertEqual(try MuxPacket.payloadSize(header), frame.count - 16)
        var invalid = Data(header)
        invalid[12] = 2
        XCTAssertThrowsError(try MuxPacket.payloadSize(invalid))
        XCTAssertThrowsError(try MuxPacket.payloadSize(Data(header.dropLast())))
        let body = try XCTUnwrap(PropertyListSerialization.propertyList(from: frame.dropFirst(16), format: nil) as? [String: Any])
        XCTAssertEqual(body["MessageType"] as? String, "Connect")
        XCTAssertEqual(body["PortNumber"] as? UInt16, RemotePairing.usbPort.bigEndian)
        XCTAssertEqual(body["DeviceID"] as? Int, 7)
        XCTAssertTrue(try MuxPacket.didConnect(plist(["MessageType": "Result", "Number": 0])))
        XCTAssertFalse(try MuxPacket.didConnect(plist(["MessageType": "Result", "Number": 3])))
        XCTAssertFalse(try MuxPacket.didConnect(plist(["MessageType": "Attached", "Number": 0])))
    }
}
