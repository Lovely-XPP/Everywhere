"""跨平台辅助进程、USB 目标绑定和 BlueZ SDP 解析的无设备回归。"""
import asyncio
from pathlib import Path
import socket
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from host_platform import binary
from linux_rfcomm import channel_for, IAP2
from mac_bluetooth import MacBluetooth
from remote import usb_channel


class Helpers(unittest.TestCase):
    def test_native_program_suffix(self):
        for platform,suffix in [('win32','.exe'),('darwin',''),('linux','')]:
            with patch.object(sys,'platform',platform):
                self.assertEqual(binary(Path('bin'),'rfcomm').name,'rfcomm'+suffix)

    def test_rfcomm_channel_belongs_to_selected_service(self):
        def record(uuid, channel):
            return f"""<record>
              <attribute id="0x0001"><sequence><uuid value="{uuid}"/></sequence></attribute>
              <attribute id="0x0004"><sequence><sequence><uuid value="0x0003"/>
              <uint8 value="{channel}"/></sequence></sequence></attribute></record>"""
        other=record('0x1101','0x01')
        self.assertIsNone(channel_for(other))
        self.assertEqual(channel_for(other+'\n'+record(IAP2,'0x14')),20)
        self.assertIsNone(channel_for(record(IAP2,'0xff')))


class PlatformSessions(unittest.IsolatedAsyncioTestCase):
    async def test_usb_remote_uses_selected_physical_device(self):
        first,second=socket.socketpair()
        self.addCleanup(second.close)
        selected=SimpleNamespace(serial='AA-BB',connection_type='USB',connect=AsyncMock(return_value=first))
        other=SimpleNamespace(serial='CC',connection_type='USB',connect=AsyncMock())
        network=SimpleNamespace(serial='AABB',connection_type='Network',connect=AsyncMock())
        service=SimpleNamespace(list_devices=AsyncMock(return_value=[network,other,selected]))
        with patch.dict(sys.modules,{'pymobiledevice3.usbmux':service}):
            reader,writer=await usb_channel('aabb')
            try:
                second.sendall(b'ok')
                self.assertEqual(await reader.readexactly(2), b'ok')
            finally:
                writer.close()
                await writer.wait_closed()
        selected.connect.assert_awaited_once_with(49371)
        other.connect.assert_not_awaited()
        network.connect.assert_not_awaited()

    async def test_mac_reverse_binds_command_to_live_process(self):
        bridge=MacBluetooth(Path('.'))
        bridge.proc=object()
        bridge.request=AsyncMock(return_value={'peers':['phone']})
        device='phone'.encode().hex()
        self.assertIn(device,await bridge.peers())
        with self.assertRaises(ConnectionError):
            await bridge.marker(device,'123456',(1,2),object())
        await bridge.marker(device,'123456',(1,2),bridge.proc)
        bridge.request.assert_awaited_with('marker', id='phone', code='123456',coords=(1,2))


@unittest.skipUnless(sys.platform == 'linux','Linux D-Bus integration')
class BlueZBindings(unittest.IsolatedAsyncioTestCase):
    async def test_subscribed_phones_receive_separate_descriptors(self):
        import shutil
        from dbus_next import Message, MessageType, Variant
        from dbus_next.aio import MessageBus
        from linux_gatt import Indications
        if not shutil.which('dbus-daemon'):
            self.skipTest('dbus-daemon unavailable')
        daemon = await asyncio.create_subprocess_exec('dbus-daemon','--session','--nofork','--print-address=1',
                                                      stdout=asyncio.subprocess.PIPE)
        buses, phones = [], []
        try:
            address=(await asyncio.wait_for(daemon.stdout.readline(),3)).decode().strip()
            for _ in range(2):
                buses.append(await MessageBus(bus_address=address,negotiate_unix_fd=True).connect())
            server,client=buses
            field=Indications('C',server)
            server.export('/test/field',field)
            for name in ('one','two'):
                reply=await client.call(Message(destination=server.unique_name,path='/test/field',
                    interface='org.bluez.GattCharacteristic1',member='AcquireNotify',signature='a{sv}',
                    body=[{'device':Variant('o','/phone/'+name),'mtu':Variant('q',64)}]))
                self.assertEqual(reply.message_type,MessageType.METHOD_RETURN,reply.body)
                self.assertEqual(reply.body[1],64)
                phones.append(socket.socket(fileno=reply.unix_fds[reply.body[0]]))
            for phone in phones: phone.setblocking(False)
            channel,capacity=field.peers[b'/phone/two'.hex()]
            self.assertEqual(capacity,61)
            channel.send(b'point')
            self.assertEqual(phones[1].recv(32),b'point')
            with self.assertRaises(BlockingIOError): phones[0].recv(32)
            for phone in phones: phone.close()
            async with asyncio.timeout(2):
                while field.peers: await asyncio.sleep(.01)
        finally:
            for phone in phones: phone.close()
            for bus in buses: bus.disconnect()
            daemon.terminate()
            await daemon.wait()
