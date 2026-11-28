"""通过传输替身核对断线退避、认证失败和恢复发送的边界。"""
import asyncio
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch

from accessory_location import cli
from accessory_location.wire import Message, parameter


class ReconnectTests(unittest.IsolatedAsyncioTestCase):
    async def test_backoff_and_terminal_failures(self):
        args = SimpleNamespace(until_stopped=True, stdin_updates=True)
        retry = "EW_OPEN_ERROR channel=7 status=0xe00002d5 record=live cause=busy"
        for error, count in [(RuntimeError(retry), 3), (RuntimeError("EW_WINDOWS_RFCOMM_ERROR status=10060"), 3),
                             (RuntimeError("EW_WINDOWS_RFCOMM_ERROR status=10051"), 3),
                             (RuntimeError("EW_WINDOWS_SDP_ERROR status=10051"), 3),
                             (RuntimeError("EW_WINDOWS_RFCOMM_ERROR status=10013"), 1), (RuntimeError("Accessory authentication failed"), 1),
                             (RuntimeError("iAP2 service unavailable"), 1), (RuntimeError("Selected device is not paired"), 1)]:
            attempts = AsyncMock(side_effect=error)
            with patch.object(cli, "run_connection", attempts), patch.object(cli, "emit"), \
                 patch.object(cli.asyncio, "sleep", AsyncMock()) as sleep:
                with self.assertRaises(RuntimeError):
                    await cli.run(args)
                self.assertEqual(attempts.await_count, count)
                self.assertEqual([c.args[0] for c in sleep.await_args_list], [2, 5] if count == 3 else [])

    async def test_cancel_during_backoff(self):
        attempts = AsyncMock(side_effect=ConnectionError("closed"))
        with patch.object(cli, "run_connection", attempts), patch.object(cli, "emit"), \
             patch.object(cli.asyncio, "sleep", AsyncMock(side_effect=asyncio.CancelledError)):
            with self.assertRaises(asyncio.CancelledError):
                await cli.run(SimpleNamespace(until_stopped=True, stdin_updates=True))
        self.assertEqual(attempts.await_count, 1)

    async def test_reauthenticated_session_waits_for_fresh_target(self):
        args = SimpleNamespace(until_stopped=True, stdin_updates=True, bluetooth_helper="", device="same",
                               command="send", transport="bluetooth", auth_helper=None,
                               latitude=10, longitude=20, jitter=False, interval=1)
        messages = iter([Message(0x1D02), Message(0xAA05), Message(0xFFFA, parameter(2)), None, None, None])
        lines = []
        link = AsyncMock()
        events = []
        async def receive(_):
            msg = next(messages)
            if msg and msg.identifier == 0xFFFA:
                lines.append(b'{"latitude":30,"longitude":40,"generation":0}\n')
            elif msg is None and not link.send.await_count:
                lines.append(b'{"latitude":50,"longitude":60,"generation":1}\n')
            elif msg is None:
                lines.append(b'')
            return msg
        link.receive.side_effect = receive
        os = SimpleNamespace(getppid=lambda: 123, read=lambda *_: lines.pop(0))
        with patch.object(cli, "Link", return_value=link), patch.object(cli, "controller_address", AsyncMock()), \
             patch.object(cli.BluetoothStream, "open_detected", AsyncMock()), patch.object(cli, "os", os), \
             patch.object(cli, "pending_input", side_effect=lambda: bool(lines)), patch.object(cli, "emit", side_effect=lambda **e: events.append(e)):
            await cli.run_connection(args, 123, 1, cli.Delivery(count=3))
        link.send.assert_awaited_once()
        self.assertEqual([e["needs_confirmation"] for e in events if e["event"] == "reconnected"], [True])
        self.assertEqual([(e["latitude"], e["longitude"], e["count"]) for e in events
                          if e["event"] == "location_link_acknowledged"], [(50, 60, 4)])
        link.close.assert_awaited_once()

    async def test_connected_session_waits_for_explicit_point(self):
        args = SimpleNamespace(until_stopped=True, stdin_updates=True, bluetooth_helper="", device="phone",
                               command="connect", transport="bluetooth", auth_helper=None, interval=1, jitter=False)
        messages = iter([Message(0x1D02), Message(0xAA05), Message(0xFFFA, parameter(2)), None, None])
        lines = []
        link = AsyncMock()
        async def receive(_):
            message = next(messages)
            if message is None:
                if not any(event["event"] == "target_updated" for event in events):
                    link.send.assert_not_awaited()
                    lines.append(b'{"latitude":31,"longitude":121,"generation":0,"jitter":false}\n')
                else:
                    lines.append(b'')
            return message
        link.receive.side_effect = receive
        events = []
        proc = SimpleNamespace(getppid=lambda: 123, read=lambda *_: lines.pop(0))
        with patch.object(cli, "Link", return_value=link), patch.object(cli, "controller_address", AsyncMock()), \
             patch.object(cli.BluetoothStream, "open_detected", AsyncMock()), patch.object(cli, "os", proc), \
             patch.object(cli, "pending_input", side_effect=lambda: bool(lines)), patch.object(cli, "emit", side_effect=lambda **e: events.append(e)):
            await cli.run_connection(args, 123, 0, cli.Delivery())
        link.send.assert_awaited_once()
        names = [event["event"] for event in events]
        self.assertLess(names.index("target_updated"), names.index("location_link_acknowledged"))
