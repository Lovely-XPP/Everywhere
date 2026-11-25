import DeviceBackend
import Foundation
import HostSession
import ScenarioKit
import XCTest

/// 在临时目录用短小的协议替身检查现代后端，无需安装第三方 Python 包或连接 Apple 设备。
final class ModernBackendTests: XCTestCase {
    private let deviceID = "00008030-0011223344556677"

    /// 执行同一实例的连续命令，检验就绪、请求关联和正常回执。
    func testSetAndClearWithMatchingReceipts() async throws {
        let script = #"""
        import json, sys
        device = sys.argv[-1]
        print(json.dumps(dict(event="ready", deviceID=device, productVersion="17.4")), flush=True)
        for line in sys.stdin:
            request = json.loads(line)
            if request["command"] == "set":
                assert request["latitude"] == 20 and request["longitude"] == -45
            print(json.dumps(dict(event="receipt", deviceID=device, requestID=request["requestID"],
                                  command=request["command"], status="sent", message="ok")), flush=True)
        """#
        try await withBackend(script: script) { backend in
            try await backend.set(try GeoPoint(latitude: 20, longitude: -45), deviceID: deviceID)
            try await backend.clear(deviceID: deviceID)
        }
    }

    /// 子进程报告另一个目标设备时，必须在本次定位请求发出之前失败。
    func testMismatchedReadyDeviceRejectsRequest() async throws {
        let script = #"""
        import json, sys
        print(json.dumps(dict(event="ready", deviceID="other-device", productVersion="17.4")), flush=True)
        for line in sys.stdin:
            sys.exit(2)
        """#
        try await withBackend(script: script) { backend in
            do {
                try await backend.clear(deviceID: deviceID)
                XCTFail("无权把其他目标设备的就绪消息当作成功。")
            } catch {
                // 该 API 抛错即可证明错误设备没有提供成功的清除回执。
            }
        }
    }

    /// 目标设备相同，仍不能接受属于其他请求的回执；保留未知状态以便主动清除。
    func testUnrelatedReceiptDoesNotAcceptLocation() async throws {
        let script = #"""
        import json, sys
        device = sys.argv[-1]
        print(json.dumps(dict(event="ready", deviceID=device, productVersion="17.4")), flush=True)
        for line in sys.stdin:
            request = json.loads(line)
            print(json.dumps(dict(event="receipt", deviceID=device, command=request["command"],
                                  requestID="different-request", status="sent")), flush=True)
        """#
        try await withBackend(script: script) { backend in
            let session = DeviceSession(deviceID: deviceID, backend: backend)
            do {
                try await session.apply(try GeoPoint(latitude: 5, longitude: 6))
                XCTFail("收到了与本次请求无关的回执。")
            } catch {
                let status = await session.status
                XCTAssertEqual(status, .unknown)
            }
        }
    }

    /// 创建测试用 JSONL 子进程脚本，仅使用开发环境随附的 Python 标准库。
    private func withBackend(
        script: String,
        perform: (ModernLocationBackend) async throws -> Void
    ) async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path), "需要系统 Python 3")
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("py")
        try script.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        try await perform(ModernLocationBackend(pythonURL: python, scriptURL: file))
    }
}
