import Foundation
import HostSession
import ScenarioKit
@testable import DeviceBackend
import XCTest

/// 用内存链路连接生产发送编码与手机接收状态机，不需要蓝牙射频或真机。
@MainActor
final class BluetoothLocationTests: XCTestCase {
    /// 系统连接可在设备停止广播时仍被发现，重叠记录保留广播名和系统状态。
    func testScanMergesConnectedAndAdvertisingPhones() {
        let nearby = UUID(), both = UUID(), system = UUID()
        let list = BluetoothTarget.merge(advertised: [nearby: "A", both: "B"],
                                         connected: [both: "B-system", system: "C"])
        XCTAssertEqual(list.map(\.id), [nearby, both, system].map(\.uuidString))
        XCTAssertEqual(list.map(\.name), ["A", "B", "C"])
        XCTAssertEqual(list.map(\.systemConnected), [false, true, true])
    }

    func testSetChangeAndClear() async throws {
        let phone = UUID(), mac = UUID()
        var inbox = BluetoothPointInbox()
        var writes = 0
        let backend = BluetoothLocationBackend { target, payload in
            let data = payload.data(supportsRMC: true, capacity: 182)
            XCTAssertEqual(target, phone)
            XCTAssertEqual(data.first, writes < 2 ? 2 : 0)
            try inbox.receive(data, code: "786234", from: mac)
            writes += 1
        }
        let session = DeviceSession(deviceID: phone.uuidString, backend: backend)
        let first = try GeoPoint(latitude: -90, longitude: 180)
        let second = try GeoPoint(latitude: 23.129163, longitude: -113.264435)
        do { try await session.apply(first); XCTFail("缺少接收码") }
        catch is BackendPreflightError {}
        XCTAssertEqual(writes, 0)
        backend.setCode("786234", for: phone.uuidString)
        try await session.apply(first)
        XCTAssertEqual(inbox.point, first)
        try await session.apply(second)
        XCTAssertEqual(inbox.point, second)
        try await session.clear()
        XCTAssertNil(inbox.point)
        XCTAssertEqual(writes, 3)
    }

    /// 使用独立校验向量覆盖 UTC、边界进位、格式协商与最低 ATT 容量。
    func testRMCSentenceAndCompatibility() throws {
        let point = try GeoPoint(latitude: -89.999999999, longitude: 179.999999999)
        let command = BluetoothPointCommand(point)
        let payload = try command.payload(code: "123456", at: Date(timeIntervalSince1970: 0))
        let packet = payload.data(supportsRMC: true, capacity: 182)
        XCTAssertEqual(String(decoding: packet.dropFirst(7), as: UTF8.self),
                       "$GPRMC,000000,A,9000.00000,S,18000.00000,E,,,010170,,,S*78\r\n")
        XCTAssertEqual(payload.data(supportsRMC: true, capacity: packet.count), packet)
        let legacy = try command.encode(code: "123456")
        XCTAssertEqual(payload.data(supportsRMC: false, capacity: 182), legacy)
        XCTAssertEqual(payload.data(supportsRMC: true, capacity: 16), legacy)
    }

    /// 已知标准 RMC 样例可以独立解码。损坏的校验和不得改变位置或抢占接收权。
    func testKnownRMCAndCorruptPacket() throws {
        let header = Data([2]) + Data("123456".utf8)
        let sentence = "$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A\r\n"
        let valid = header + Data(sentence.utf8)
        let damaged = header + Data(sentence.replacingOccurrences(of: "4807", with: "4808").utf8)
        var inbox = BluetoothPointInbox()
        XCTAssertThrowsError(try inbox.receive(damaged, code: "123456", from: UUID()))
        let owner = UUID()
        try inbox.receive(valid, code: "123456", from: owner)
        let point = try XCTUnwrap(inbox.point)
        XCTAssertEqual(point.latitude, 48.1173, accuracy: 1e-9)
        XCTAssertEqual(point.longitude, 11.5166666667, accuracy: 1e-9)
        XCTAssertThrowsError(try inbox.receive(damaged, code: "123456", from: owner))
        XCTAssertEqual(inbox.point, point)
    }

    func testRejectedWritesKeepPreviousPointAndOwner() throws {
        let mac = UUID(), code = "123456"
        let point = try GeoPoint(latitude: 0, longitude: -180)
        let set = try BluetoothPointCommand(point).encode(code: code)
        let clear = try BluetoothPointCommand(nil).encode(code: code)
        var inbox = BluetoothPointInbox()
        XCTAssertThrowsError(try inbox.receive(set, code: "999999", from: UUID()))
        try inbox.receive(set, code: code, from: mac)
        XCTAssertThrowsError(try inbox.receive(clear, code: code, from: UUID()))
        var invalid = set
        invalid.replaceSubrange(7..<11, with: [0x7f, 0xff, 0xff, 0xff])
        for data in [Data(set.dropLast()), set + [0], invalid] {
            XCTAssertThrowsError(try inbox.receive(data, code: code, from: mac))
        }
        XCTAssertEqual(inbox.point, point)
        inbox.clearLocalPoint()
        XCTAssertNil(inbox.point)
        XCTAssertThrowsError(try inbox.receive(set, code: code, from: UUID()))
        try inbox.receive(set, code: code, from: mac)
        XCTAssertEqual(inbox.point, point)
    }
}
