"""用子进程替身验证通道就绪、错误传播和探测的先后顺序。"""
import asyncio
import pathlib
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

from accessory_location.transport import BluetoothStream


class OpenTests(unittest.IsolatedAsyncioTestCase):
    async def launch(self, body, emit=None):
        with tempfile.TemporaryDirectory() as directory:
            bridge = pathlib.Path(directory, "bridge")
            bridge.write_text("#!/bin/sh\n" + body)
            bridge.chmod(0o700)
            return await BluetoothStream.open(str(bridge), "00:00:00:00:00:00", emit)

    async def test_open_before_detection(self):
        stream = await self.launch("echo EW_OPEN_READY >&2\nexec cat")
        try:
            await asyncio.wait_for(stream.detect(), 1)
        finally:
            await stream.close()

    async def test_native_failure_reaches_client(self):
        record = "EW_OPEN_ERROR channel=7 status=0xe00002d5 record=live cause=busy"
        with self.assertRaises(RuntimeError) as error:
            await self.launch(f"echo 'system diagnostic' >&2\necho '{record}' >&2\nexit 4")
        self.assertEqual(str(error.exception), record)

    async def test_windows_socket_error_reaches_host(self):
        record = "EW_WINDOWS_RFCOMM_ERROR status=10060"
        with self.assertRaisesRegex(RuntimeError, record):
            await self.launch(f"echo '{record}' >&2\nexit 4")

    async def test_stale_cache_reopens_same_target_with_live_lookup(self):
        cached, live = AsyncMock(), AsyncMock()
        cached.cached_channel = True
        cached.detect.side_effect = asyncio.IncompleteReadError(b"", 6)
        address = "00:00:00:00:00:01"
        with patch.object(BluetoothStream, "open", AsyncMock(side_effect=[cached, live])) as start:
            stream = await BluetoothStream.open_detected("bridge", address, lambda **_: None)
        self.assertIs(stream, live)
        self.assertEqual([call.kwargs["live_only"] for call in start.await_args_list], [False, True])
        self.assertTrue(all(call.args[1] == address for call in start.await_args_list))
        cached.close.assert_awaited_once()
        live.detect.assert_awaited_once()

    async def test_missing_service_has_no_detect(self):
        with self.assertRaisesRegex(RuntimeError, "iAP2 service unavailable"):
            await self.launch("exit 6")


    async def test_baseband_failure_precedes_discovery(self):
        updates = []
        record = "EW_BASEBAND_ERROR status=0xe00002d6"
        with self.assertRaises(RuntimeError) as error:
            await self.launch(f"echo EW_PHASE baseband >&2\necho '{record}' >&2\nexit 7",
                              lambda **event: updates.append(event))
        self.assertEqual(str(error.exception), record)
        self.assertEqual(updates, [{"event": "bluetooth_stage", "stage": "baseband"}])
