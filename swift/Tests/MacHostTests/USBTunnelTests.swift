import Darwin
import Foundation
@testable import MacHost
import Network
import os
import RemoteControl
import XCTest

/// 在独立回环端口上模拟系统守护进程，把 Connect 后的流转发给独立的回环 TLS 手机端。
/// 不读写真实的 usbmuxd、设备位置或钥匙串。需要测试进程可以监听本机 socket。
final class USBTunnelTests: XCTestCase {
    private let queue = DispatchQueue(label: "VirtualLocation.tests.usb")

    /// 等待监听器或连接就绪。单一串行队列负责完成回调及超时，避免重复恢复。
    private func listenerReady(_ listener: NWListener) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let timeout = DispatchWorkItem { listener.cancel() }
            queue.asyncAfter(deadline: .now() + 5, execute: timeout)
            listener.stateUpdateHandler = { state in
                let failure: NWError?
                switch state {
                case .ready: failure = nil
                case .waiting(let e), .failed(let e): failure = e
                case .cancelled: failure = .posix(.ETIMEDOUT)
                default: return
                }
                let firstResult = resumed.withLock { value in
                    if value { return false }
                    value = true
                    return true
                }
                guard firstResult else { return }
                timeout.cancel()
                if let failure { continuation.resume(throwing: failure) } else { continuation.resume() }
            }
            listener.start(queue: queue)
        }
    }

    private func request(_ link: RemoteLink) async throws -> [String: Any] {
        let length = try MuxPacket.payloadSize(try await link.read(16))
        let payload = try await link.read(length)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any])
    }

    /// 透明转发单向字节，任一端 EOF 或报错时结束这对连接。
    private func relay(_ from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { data, _, eof, error in
            guard let data, !data.isEmpty, error == nil else { from.cancel(); to.cancel(); return }
            to.send(content: data, completion: .contentProcessed { error in
                if error != nil || eof { from.cancel(); to.cancel() } else { self.relay(from, to: to) }
            })
        }
    }

    func testMuxNegotiationThenReverseTLSRequestAndReceipt() async throws {
        try await exerciseMux(unixPath: nil)
    }

    /// 另测生产使用的 UNIX 端点；只有运行环境明确拒绝 UNIX bind 时才跳过。
    func testMuxOverUnixSocket() async throws {
        let path = "/tmp/vloc-" + UUID().uuidString
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd); unlink(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8CString.map { UInt8(bitPattern: $0) }) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result < 0, errno == EPERM { throw XCTSkip("当前环境禁止创建 UNIX socket。") }
        XCTAssertEqual(result, 0)
        unlink(path)
        try await exerciseMux(unixPath: path)
    }

    private func exerciseMux(unixPath: String?) async throws {
        let key = try RemotePairing.generate()
        let phoneSettings = try RemotePairing.parameters(key)
        phoneSettings.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let phone = try NWListener(using: phoneSettings)
        defer { phone.cancel() }
        let request = RemoteRequest(.status)
        let receipt = expectation(description: "手机收到同一请求的回执")
        phone.newConnectionHandler = { connection in
            connection.start(queue: self.queue)
            Task {
                defer { connection.cancel(); receipt.fulfill() }
                do {
                    let link = RemoteLink(connection)
                    try await link.send(request)
                    let reply = try await link.receive(RemoteReply.self)
                    XCTAssertEqual(reply.id, request.id)
                    XCTAssertEqual(reply.phase, .status)
                } catch { XCTFail(error.localizedDescription) }
            }
        }
        do { try await listenerReady(phone) }
        catch NWError.posix(.EPERM) { throw XCTSkip("当前测试环境禁止监听本机端口。") }

        let port = try XCTUnwrap(phone.port)
        let settings = NWParameters.tcp
        settings.requiredLocalEndpoint = unixPath.map { NWEndpoint.unix(path: $0) } ?? .hostPort(host: "127.0.0.1", port: .any)
        let mux = try NWListener(using: settings)
        defer { mux.cancel() }
        mux.newConnectionHandler = { connection in
            connection.start(queue: self.queue)
            Task {
                do {
                    let link = RemoteLink(connection)
                    let fields = try await self.request(link)
                    switch fields["MessageType"] as? String {
                    case "ListDevices":
                        let fields: [String: Any] = ["DeviceID": 12, "Properties": ["ConnectionType": "USB", "SerialNumber": "example"]]
                        try await link.sendBytes(MuxPacket.encode(["DeviceList": [fields]]))
                        connection.cancel()
                    case "Connect":
                        XCTAssertEqual(fields["DeviceID"] as? UInt32, 12)
                        XCTAssertEqual(fields["PortNumber"] as? UInt16, RemotePairing.usbPort.bigEndian)
                        let reply = try MuxPacket.encode(["MessageType": "Result", "Number": 0])
                        try await link.sendBytes(reply.prefix(7))
                        try await link.sendBytes(reply.dropFirst(7))
                        let peer = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
                        peer.start(queue: self.queue)
                        self.relay(connection, to: peer)
                        self.relay(peer, to: connection)
                    default: XCTFail("意外的 usbmux 请求"); connection.cancel()
                    }
                } catch { XCTFail(error.localizedDescription); connection.cancel() }
            }
        }
        try await listenerReady(mux)
        let address = try unixPath.map { NWEndpoint.unix(path: $0) } ?? .hostPort(host: "127.0.0.1", port: XCTUnwrap(mux.port))
        let (connection, number) = try await USBRemoteConnection.connection(device: "example", code: key, endpoint: address)
        XCTAssertEqual(number, 12)
        let timeout = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + 8, execute: timeout)
        defer { timeout.cancel(); connection.cancel() }
        connection.start(queue: queue)
        let link = RemoteLink(connection)
        let received = try await link.receive(RemoteRequest.self)
        XCTAssertEqual(received, request)
        try await link.send(RemoteReply(received, .status, "已连接"))
        await fulfillment(of: [receipt], timeout: 5)
    }
}
