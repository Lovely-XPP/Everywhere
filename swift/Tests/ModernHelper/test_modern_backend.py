"""ModernBackend 的标准库测试；通过替身及本地管道验证，不连接设备或导入 pymobiledevice3。"""

from contextlib import AsyncExitStack, asynccontextmanager
import asyncio
import importlib.util
import io
import json
import os
from pathlib import Path
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch


SCRIPT = Path(__file__).resolve().parents[2] / "Host" / "ModernBackend" / "modern_backend.py"
SPEC = importlib.util.spec_from_file_location("modern_backend", SCRIPT)
backend = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backend)
UDID = "00008030-00123456ABCDEF01"


def command(request_id, action, **fields):
    """生成类似主机 stdin 的单行 JSON；不触及任何真机。"""
    return (json.dumps(dict(requestID=request_id, command=action, **fields)) + "\n").encode()


class CommandSessionTests(unittest.IsolatedAsyncioTestCase):
    """使用异步定位服务替身检查请求结果、去重与失败后的恢复语义。"""

    async def asyncSetUp(self):
        self.output = io.StringIO()
        self.output_patch = patch.object(backend, "PROTOCOL_OUT", self.output)
        self.output_patch.start()
        self.addCleanup(self.output_patch.stop)
        self.location = SimpleNamespace(set=AsyncMock(), clear=AsyncMock())
        self.session = backend.CommandSession(UDID, self.location)

    def events(self):
        """返回辅助进程已写出的结构化事件。"""
        return [json.loads(line) for line in self.output.getvalue().splitlines()]

    async def test_set_change_clear_and_reused_request(self):
        a = command("a", "set", latitude=10, longitude=20)
        b = command("b", "set", latitude=-45, longitude=-179)
        await self.session.process(a)
        await self.session.process(a)
        await self.session.process(b)
        await self.session.process(command("c", "clear"))
        # 即便已清除，重复收到旧请求也只复用旧回执，绝不重新设置。
        await self.session.process(a)
        self.assertEqual(self.location.set.await_count, 2)
        self.location.set.assert_awaited_with(-45.0, -179.0)
        self.location.clear.assert_awaited_once()
        self.assertFalse(self.session.may_need_clear)
        results = self.events()
        self.assertEqual([event["status"] for event in results], ["sent"] * 5)
        self.assertEqual(results[0], results[1])
        self.assertEqual(results[0], results[4])

    async def test_request_id_conflict(self):
        await self.session.process(command("same", "set", latitude=1, longitude=2))
        await self.session.process(command("same", "set", latitude=3, longitude=4))
        await self.session.process(command("same", "clear"))
        self.location.set.assert_awaited_once_with(1.0, 2.0)
        self.location.clear.assert_not_awaited()
        self.assertEqual([e["status"] for e in self.events()], ["sent", "rejected", "rejected"])

    async def test_coordinates_and_target_validation(self):
        invalid_points = [(91, 0), (0, -181), (float("nan"), 0), (0, float("inf")), (True, 0), (0, "1")]
        for index, (latitude, longitude) in enumerate(invalid_points):
            await self.session.process(command(str(index), "set", latitude=latitude, longitude=longitude))
        await self.session.process(command("wrong-device", "clear", deviceID="00000000-0000000000000000"))
        self.location.set.assert_not_awaited()
        self.location.clear.assert_not_awaited()
        self.assertTrue(all(event["status"] == "rejected" for event in self.events()))
        await self.session.process(command("bounds", "set", latitude=-90, longitude=180, deviceID=UDID.lower()))
        self.location.set.assert_awaited_once_with(-90.0, 180.0)

    async def test_ambiguous_set_marks_pending_clear(self):
        self.location.set.side_effect = ConnectionError("模拟连接异常")
        self.assertEqual(await self.session.process(command("a", "set", latitude=1, longitude=2)), (True, False))
        self.assertTrue(self.session.may_need_clear)
        self.assertEqual(self.events()[0]["status"], "unknown")

    async def test_failed_clear_keeps_pending_state(self):
        await self.session.process(command("a", "set", latitude=0, longitude=0))
        self.location.clear.side_effect = TimeoutError()
        self.assertEqual(await self.session.process(command("b", "clear")), (True, False))
        self.assertTrue(self.session.may_need_clear)
        self.assertEqual(self.events()[-1]["status"], "unknown")
        with self.assertRaises(TimeoutError):
            await self.session.clear_owned()
        self.assertTrue(self.session.may_need_clear)

    async def test_quit_clears_only_when_set_owned(self):
        await self.session.process(command("a", "quit"))
        self.location.clear.assert_not_awaited()
        await self.session.process(command("b", "set", latitude=0, longitude=0))
        self.assertEqual(await self.session.process(command("c", "quit")), (True, True))
        self.location.clear.assert_awaited_once()
        self.assertFalse(self.session.may_need_clear)

    async def consume_pipe(self, lines):
        """向本地管道写完指令后关闭写端，验证 EOF 生命周期和清除事件。"""
        read_fd, write_fd = os.pipe()
        with os.fdopen(read_fd, "rb") as stream:
            with os.fdopen(write_fd, "wb") as writer:
                writer.write(b"".join(lines))
            tunnel = SimpleNamespace(rsd=object())
            with patch.object(backend.sys, "stdin", SimpleNamespace(buffer=stream)):
                result = await backend.command_loop(UDID, tunnel, self.location, asyncio.Event())
                await asyncio.sleep(0)  # 让关闭本地管道的回调处理完成。
                return result

    async def test_eof_does_not_clear_unowned_location(self):
        self.assertEqual(await self.consume_pipe([]), 0)
        self.location.clear.assert_not_awaited()
        self.assertEqual(self.events(), [])

    async def test_eof_clears_owned_location(self):
        self.assertEqual(await self.consume_pipe([command("a", "set", latitude=1, longitude=2)]), 0)
        self.location.clear.assert_awaited_once()
        self.assertEqual([(event["event"], event["status"]) for event in self.events()],
                         [("receipt", "sent"), ("cleanup", "sent")])

    async def test_eof_failed_cleanup_reports_unknown(self):
        self.location.clear.side_effect = ConnectionError()
        self.assertEqual(await self.consume_pipe([command("a", "set", latitude=1, longitude=2)]), 2)
        self.assertEqual(self.events()[-1]["event"], "cleanup")
        self.assertEqual(self.events()[-1]["status"], "unknown")

    async def test_failed_set_does_not_execute_queued_set(self):
        self.location.set.side_effect = TimeoutError()
        self.assertEqual(await self.consume_pipe([command("a", "set", latitude=1, longitude=2),
                                                  command("b", "set", latitude=3, longitude=4)]), 2)
        self.location.set.assert_awaited_once_with(1.0, 2.0)
        self.location.clear.assert_awaited_once()


class PreflightTests(unittest.IsolatedAsyncioTestCase):
    """仅通过替身检查 USB 设备唯一匹配及配对/平台范围前置条件。"""

    def fake_client(self, **changes):
        """创建具有异步退出行为的 lockdown 替身。"""
        class Client:
            paired = True
            short_info = dict(UniqueDeviceID=UDID, ConnectionType="USB", DeviceClass="iPhone")
            product_version = "17.4.1"

            async def __aenter__(self):
                return self

            async def __aexit__(self, *_):
                return None

        client = Client()
        for key, value in changes.items():
            setattr(client, key, value)
        return client

    async def test_match_case_and_dash_uses_reported_usb_identifier(self):
        reported_usb = UDID.replace("-", "").lower()
        list_devices = AsyncMock(return_value=[SimpleNamespace(connection_type="Network", serial=UDID),
                                               SimpleNamespace(connection_type="USB", serial=reported_usb)])
        create = AsyncMock(return_value=self.fake_client())
        self.assertEqual(await backend.preflight(list_devices, create, UDID), (reported_usb, "17.4.1"))
        create.assert_awaited_once_with(serial=reported_usb, autopair=False, connection_type="USB")

    async def test_ambiguous_or_network_only_rejected_without_connection(self):
        for devices in ([SimpleNamespace(connection_type="Network", serial=UDID)],
                        [SimpleNamespace(connection_type="USB", serial=UDID),
                         SimpleNamespace(connection_type="USB", serial=UDID.lower())]):
            create = AsyncMock()
            with self.assertRaises(backend.Rejected):
                await backend.preflight(AsyncMock(return_value=devices), create, UDID)
            create.assert_not_awaited()

    async def test_unpaired_and_old_versions_rejected(self):
        list_devices = AsyncMock(return_value=[SimpleNamespace(connection_type="USB", serial=UDID)])
        for client in (self.fake_client(paired=False), self.fake_client(product_version="17.3.1")):
            create = AsyncMock(return_value=client)
            with self.assertRaises(backend.Rejected):
                await backend.preflight(list_devices, create, UDID)
            create.assert_awaited_once_with(serial=UDID, autopair=False, connection_type="USB")


class HandshakeTests(unittest.IsolatedAsyncioTestCase):
    """每次准备都核验身份；仅允许在发出 ready 之前重开通道。"""

    async def check_handshake(self, failures, expected=None, stop_on_failure=False):
        events = []
        stop = asyncio.Event()

        @asynccontextmanager
        async def tunnel(**kwargs):
            self.assertEqual(kwargs, dict(serial=UDID, autopair=False, remotepairing_fallback=False))
            events.append("open")
            try:
                yield SimpleNamespace(udid=UDID)
            finally:
                events.append("close")

        @asynccontextmanager
        async def dvt(_rsd):
            if failures:
                if stop_on_failure:
                    stop.set()
                raise failures.pop(0)
            yield object()

        @asynccontextmanager
        async def location(_dvt):
            yield object()

        check = AsyncMock(return_value=(UDID, "17.4"))
        with patch.object(backend, "preflight", check):
            async with AsyncExitStack() as stack:
                prepare = backend.prepare_channel(UDID, stack, stop, None, None, tunnel, dvt, location)
                if expected:
                    with self.assertRaises(expected):
                        await prepare
                elif stop_on_failure:
                    self.assertIsNone(await prepare)
                else:
                    result = await prepare
                    self.assertEqual(result[2], "17.4")
                    self.assertEqual(events[-1], "open")
        self.assertEqual(events, ["open", "close"] * check.await_count)
        return check.await_count

    async def test_retry_once_with_fresh_identity_check(self):
        self.assertEqual(await self.check_handshake([ConnectionResetError()]), 2)
        self.assertEqual(await self.check_handshake([TimeoutError(), TimeoutError()], TimeoutError), 2)

    async def test_refusal_and_cancellation_skip_retry(self):
        self.assertEqual(await self.check_handshake([backend.Rejected("配对失效")], backend.Rejected), 1)
        self.assertEqual(await self.check_handshake([ConnectionResetError()], stop_on_failure=True), 1)


if __name__ == "__main__":
    unittest.main()
