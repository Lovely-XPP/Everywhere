import XCTest
import ScenarioKit
import HostSession

/// 验证本机会话的回执、互斥和异常恢复逻辑；不连接真实设备。
final class DeviceSessionTests: XCTestCase {
    /// 相同命令仅复用近期真实回执；清除、断线和超出时间窗后不得冒用。
    func testRepeatedPointReceiptHasBoundedLifetime() async throws {
        let backend = TestBackend()
        let session = DeviceSession(deviceID: "test-device", backend: backend)
        let point = try GeoPoint(latitude: 1, longitude: 2)
        let first = try await session.applyWithReceipt(point)
        let repeated = try await session.applyWithReceipt(point)
        XCTAssertTrue(first)
        XCTAssertFalse(repeated)
        try await Task.sleep(for: .milliseconds(2050))
        let later = try await session.applyWithReceipt(point)
        XCTAssertTrue(later)
        await session.markDisconnected()
        do { try await session.apply(point); XCTFail("未知会话不能复用回执") }
        catch SessionError.needsClear {}
        try await session.clear()
        let afterClear = try await session.applyWithReceipt(point)
        XCTAssertTrue(afterClear)
        let writes = await backend.commands
        XCTAssertEqual(writes, [.set(point, "test-device"), .set(point, "test-device"),
                                .clear("test-device"), .set(point, "test-device")])
    }

    func testApplyReplaceAndClear() async throws {
        let backend = TestBackend()
        let session = DeviceSession(deviceID: "test-device", backend: backend)
        let first = try GeoPoint(latitude: 22.5431, longitude: 114.0579)
        let second = try GeoPoint(latitude: 39.9042, longitude: 116.4074)

        await assertStatus(session, .idle)
        try await session.apply(first)
        await assertStatus(session, .accepted(first))
        try await session.apply(second)
        await assertStatus(session, .accepted(second))
        try await session.clear()
        await assertStatus(session, .idle)

        let commands = await backend.commands
        XCTAssertEqual(commands, [
            .set(first, "test-device"),
            .set(second, "test-device"),
            .clear("test-device")
        ])
    }

    func testFailuresRequireSuccessfulClearBeforeApplyingAgain() async throws {
        let backend = TestBackend()
        let session = DeviceSession(deviceID: "test-device", backend: backend)
        let point = try GeoPoint(latitude: 22, longitude: 114)

        await backend.failNextCommand()
        do {
            try await session.apply(point)
            XCTFail("应转发设点错误")
        } catch {
            XCTAssertEqual(error as? TestBackend.Failure, .noReceipt)
        }
        await assertStatus(session, .unknown)

        do {
            try await session.apply(point)
            XCTFail("未知会话应禁止重新设点")
        } catch {
            XCTAssertEqual(error as? SessionError, .needsClear)
        }

        await backend.failNextCommand()
        do {
            try await session.clear()
            XCTFail("应转发清除错误")
        } catch {
            XCTAssertEqual(error as? TestBackend.Failure, .noReceipt)
        }
        await assertStatus(session, .unknown)

        try await session.clear()
        await assertStatus(session, .idle)
        try await session.apply(point)
        await assertStatus(session, .accepted(point))

        let commands = await backend.commands
        XCTAssertEqual(commands, [
            .set(point, "test-device"),
            .clear("test-device"),
            .clear("test-device"),
            .set(point, "test-device")
        ])
    }

    func testPreflightFailuresPreservePriorStatus() async throws {
        let backend = TestBackend()
        let session = DeviceSession(deviceID: "test-device", backend: backend)
        let first = try GeoPoint(latitude: 22, longitude: 114)
        let second = try GeoPoint(latitude: 39, longitude: 116)

        await backend.failNextPreflight()
        do {
            try await session.apply(first)
            XCTFail("应转发前置错误")
        } catch {
            XCTAssertTrue(error is BackendPreflightError)
        }
        await assertStatus(session, .idle)

        try await session.apply(first)
        await backend.failNextPreflight()
        do {
            try await session.apply(second)
            XCTFail("应转发改点前置错误")
        } catch {
            XCTAssertTrue(error is BackendPreflightError)
        }
        await assertStatus(session, .accepted(first))

        await backend.failNextPreflight()
        do {
            try await session.clear()
            XCTFail("应转发清除前置错误")
        } catch {
            XCTAssertTrue(error is BackendPreflightError)
        }
        await assertStatus(session, .accepted(first))

        await session.markDisconnected()
        await backend.failNextPreflight()
        do {
            try await session.clear()
            XCTFail("未发出清除命令时不能确认未知会话已恢复")
        } catch {
            XCTAssertTrue(error is BackendPreflightError)
        }
        await assertStatus(session, .unknown)
        try await session.clear()
        await assertStatus(session, .idle)

        let commands = await backend.commands
        XCTAssertEqual(commands, [.set(first, "test-device"), .clear("test-device")])
    }

    func testPreflightFailureAfterDisconnectDoesNotRestoreAcceptedStatus() async throws {
        let backend = TestBackend()
        let session = DeviceSession(deviceID: "test-device", backend: backend)
        let point = try GeoPoint(latitude: 22, longitude: 114)
        try await session.apply(point)

        await backend.failNextPreflight()
        await backend.holdNextCommand()
        let clearing = Task { try await session.clear() }
        await backend.waitForHeldCommand()
        await session.markDisconnected()
        await backend.releaseHeldCommand()
        do {
            try await clearing.value
            XCTFail("应转发清除前置错误")
        } catch {
            XCTAssertTrue(error is BackendPreflightError)
        }
        await assertStatus(session, .unknown)

        let commands = await backend.commands
        XCTAssertEqual(commands, [.set(point, "test-device")])
    }

    /// 后端在预检中发现失联且未发出新命令时，不能保留先前设点的已接受状态。
    func testObservedConnectionLossRequiresClearEvenIfCommandWasNotSent() async throws {
        let backend = TestBackend()
        let session = DeviceSession(deviceID: "test-device", backend: backend)
        let first = try GeoPoint(latitude: 22, longitude: 114)
        let second = try GeoPoint(latitude: 39, longitude: 116)
        try await session.apply(first)

        await backend.loseConnectionBeforeNextCommand()
        do {
            try await session.apply(second)
            XCTFail("应转发已观察到的失联错误")
        } catch {
            XCTAssertTrue(error is DeviceConnectionLostError)
        }
        await assertStatus(session, .unknown)

        do {
            try await session.apply(second)
            XCTFail("失联后不得重新设点，须先清除")
        } catch {
            XCTAssertEqual(error as? SessionError, .needsClear)
        }

        await backend.loseConnectionBeforeNextCommand()
        do {
            try await session.clear()
            XCTFail("已失联且未发出清除请求不能当作成功")
        } catch {
            XCTAssertTrue(error is DeviceConnectionLostError)
        }
        await assertStatus(session, .unknown)

        try await session.clear()
        await assertStatus(session, .idle)
        let commands = await backend.commands
        XCTAssertEqual(commands, [.set(first, "test-device"), .clear("test-device")])
    }

    func testNoSecondBackendCommandDuringAwait() async throws {
        let backend = TestBackend()
        let session = DeviceSession(deviceID: "test-device", backend: backend)
        let point = try GeoPoint(latitude: 22, longitude: 114)

        await backend.holdNextCommand()
        let setting = Task { try await session.apply(point) }
        await backend.waitForHeldCommand()
        await assertStatus(session, .applying)
        do {
            try await session.apply(point)
            XCTFail("等待设点回执期间不得重复设点")
        } catch {
            XCTAssertEqual(error as? SessionError, .busy)
        }
        do {
            try await session.clear()
            XCTFail("等待设点回执期间不得并发清除")
        } catch {
            XCTAssertEqual(error as? SessionError, .busy)
        }
        await backend.releaseHeldCommand()
        try await setting.value
        await assertStatus(session, .accepted(point))

        await backend.holdNextCommand()
        let clearing = Task { try await session.clear() }
        await backend.waitForHeldCommand()
        await assertStatus(session, .clearing)
        do {
            try await session.apply(point)
            XCTFail("等待清除回执期间不得设点")
        } catch {
            XCTAssertEqual(error as? SessionError, .busy)
        }
        do {
            try await session.clear()
            XCTFail("等待清除回执期间不得重复清除")
        } catch {
            XCTAssertEqual(error as? SessionError, .busy)
        }
        await backend.releaseHeldCommand()
        try await clearing.value
        await assertStatus(session, .idle)

        let commands = await backend.commands
        XCTAssertEqual(commands, [.set(point, "test-device"), .clear("test-device")])
    }

    func testDisconnectionInvalidatesLateReceipt() async throws {
        let backend = TestBackend()
        let session = DeviceSession(deviceID: "test-device", backend: backend)
        let point = try GeoPoint(latitude: 22, longitude: 114)

        await backend.holdNextCommand()
        let setting = Task { try await session.apply(point) }
        await backend.waitForHeldCommand()
        await session.markDisconnected()
        do {
            try await session.clear()
            XCTFail("失联不能提前打开执行中的门禁")
        } catch {
            XCTAssertEqual(error as? SessionError, .busy)
        }
        await backend.releaseHeldCommand()
        do {
            try await setting.value
            XCTFail("失联前发出的命令回执不再能确认设备状态")
        } catch {
            XCTAssertEqual(error as? SessionError, .interrupted)
        }
        await assertStatus(session, .unknown)
        try await session.clear()
        try await session.apply(point)
        await session.markDisconnected()
        await assertStatus(session, .unknown)
    }

    func testCancellationBeforeDispatchAndDuringBackendWait() async throws {
        let backend = TestBackend()
        let session = DeviceSession(deviceID: "test-device", backend: backend)
        let point = try GeoPoint(latitude: 22, longitude: 114)

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await session.apply(point)
        }
        do {
            try await cancelled.value
            XCTFail("已取消的任务不得发出命令")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await assertStatus(session, .idle)
        let initialCommands = await backend.commands
        XCTAssertTrue(initialCommands.isEmpty)

        await backend.holdNextCommand()
        let setting = Task { try await session.apply(point) }
        await backend.waitForHeldCommand()
        setting.cancel()
        await backend.releaseHeldCommand()
        do {
            try await setting.value
            XCTFail("后端未取得回执时应转发取消错误")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await assertStatus(session, .unknown)
        let commands = await backend.commands
        XCTAssertEqual(commands, [.set(point, "test-device")])
    }

    private func assertStatus(
        _ session: DeviceSession,
        _ expected: SessionStatus,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let actual = await session.status
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}

/// 后端测试替身；使用 continuation 明确控制挂起点，使重入测试不依赖计时延迟。
private actor TestBackend: LocationBackend {
    enum Command: Equatable, Sendable {
        case set(GeoPoint, String)
        case clear(String)
    }

    enum Failure: Error, Equatable {
        case noReceipt
    }

    private(set) var commands: [Command] = []
    private var shouldFail = false
    private var shouldFailPreflight = false
    private var shouldLoseConnection = false
    private var shouldHold = false
    private var heldCommand: CheckedContinuation<Void, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?

    func failNextCommand() {
        shouldFail = true
    }

    func failNextPreflight() {
        shouldFailPreflight = true
    }

    /// 模拟预检中取得的失联证据，此次命令不会发往设备。
    func loseConnectionBeforeNextCommand() {
        shouldLoseConnection = true
    }

    func holdNextCommand() {
        shouldHold = true
    }

    func waitForHeldCommand() async {
        guard heldCommand == nil else { return }
        await withCheckedContinuation { continuation in
            startWaiter = continuation
        }
    }

    func releaseHeldCommand() {
        let continuation = heldCommand
        heldCommand = nil
        continuation?.resume()
    }

    func set(_ point: GeoPoint, deviceID: String) async throws {
        try await record(.set(point, deviceID))
    }

    func clear(deviceID: String) async throws {
        try await record(.clear(deviceID))
    }

    private func record(_ command: Command) async throws {
        let willFailPreflight = shouldFailPreflight
        shouldFailPreflight = false
        let willLoseConnection = shouldLoseConnection
        shouldLoseConnection = false
        if !willFailPreflight && !willLoseConnection {
            commands.append(command)
        }
        if shouldHold {
            shouldHold = false
            await withCheckedContinuation { continuation in
                heldCommand = continuation
                startWaiter?.resume()
                startWaiter = nil
            }
        }
        if willFailPreflight {
            throw BackendPreflightError("测试前置错误：命令未发出")
        }
        if willLoseConnection {
            throw DeviceConnectionLostError("测试失联错误：目标设备已不在场")
        }
        try Task.checkCancellation()
        if shouldFail {
            shouldFail = false
            throw Failure.noReceipt
        }
    }
}
