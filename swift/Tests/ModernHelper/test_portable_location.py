"""独立运行时的目标绑定、配对条件和首次开发镜像准备。需要构建机上的打包依赖。"""
import asyncio
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Host/ModernBackend"))
try:
    import portable_location as portable
except ModuleNotFoundError as error:
    if error.name != "pymobiledevice3":
        raise
    raise unittest.SkipTest("需要包内独立运行时的构建依赖") from error


class PortableTests(unittest.IsolatedAsyncioTestCase):
    async def test_usb_priority_network_and_identity(self):
        udid = "00008030-001122334455AABB"
        rows = [SimpleNamespace(serial=udid, connection_type=t) for t in ("Network", "USB")]
        client = SimpleNamespace(paired=True, short_info={"UniqueDeviceID": udid, "DeviceClass": "iPhone"}, close=AsyncMock())
        with patch.object(portable, "list_devices", AsyncMock(return_value=rows)), \
             patch.object(portable, "create_using_usbmux", AsyncMock(return_value=client)) as open_client:
            await portable.connect(udid.lower(), "auto", True)
            self.assertEqual(open_client.await_args.kwargs["connection_type"], "USB")
            self.assertTrue(open_client.await_args.kwargs["autopair"])
            await portable.connect(udid, "Network", True)
            self.assertFalse(open_client.await_args.kwargs["autopair"])
            client.short_info["UniqueDeviceID"] = "other"
            with self.assertRaises(portable.Rejected):
                await portable.connect(udid, "USB", True)
            client.close.assert_awaited_once()

    async def test_bonjour_matches_reported_udid_only(self):
        wrong = SimpleNamespace(udid="another", close=AsyncMock())
        right = SimpleNamespace(udid="00008030-001122334455AABB", close=AsyncMock())
        async def candidates(**kwargs):
            for client in (wrong, right):
                yield "::1", client
        with patch.object(portable, "get_mobdev2_lockdowns", candidates):
            self.assertIs(await portable.paired_wifi("00008030001122334455aabb"), right)
        wrong.close.assert_awaited_once()
        right.close.assert_not_awaited()

    async def test_bonjour_without_mux_and_existing_image(self):
        udid = "00008030-001122334455AABB"
        client = SimpleNamespace(paired=True, short_info={"UniqueDeviceID": udid, "DeviceClass": "iPhone"})
        with patch.object(portable, "list_devices", AsyncMock(side_effect=OSError())), \
             patch.object(portable, "paired_wifi", AsyncMock(return_value=client)) as browse:
            self.assertIs(await portable.connect(udid, "auto"), client)
            browse.assert_awaited_once_with(udid)
        with patch.object(portable, "MobileImageMounterService") as factory, \
             patch.object(portable, "image_type_for_device", return_value="Developer"), \
             patch.object(portable, "auto_mount", AsyncMock()) as mount:
            check = factory.return_value.__aenter__.return_value.is_image_mounted = AsyncMock(return_value=True)
            await portable.mount_if_needed(client)
            mount.assert_not_awaited()
            check.return_value = False
            await portable.mount_if_needed(client)
            mount.assert_awaited_once_with(client)
