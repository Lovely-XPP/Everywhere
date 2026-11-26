import asyncio
import json
from types import SimpleNamespace
import sys
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, Mock, patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from peripheral import Peripheral
from bluetooth_host import Bluetooth

class ReverseBLE(unittest.IsolatedAsyncioTestCase):
    async def fixture(self,status):
        bridge=Peripheral(Path('.'))
        bridge.peers=AsyncMock(return_value={'phone-A':{'C':20}})
        messages=asyncio.Queue()
        async def send(line):
            verb,device,char,hexdata=line.split()
            self.assertEqual((verb,device,char),('SEND','phone-A','C'))
            raw=bytes.fromhex(hexdata)
            self.assertEqual(raw[4:11],b'\x01123456')
            self.assertEqual(len(raw),19)
            await messages.put('ACK phone-B '+(raw[:4]+b'\0').hex())
            await messages.put('ACK phone-A '+(raw[:4]+bytes([status])).hex())
        bridge.command=send
        bridge.line=messages.get
        return bridge
    async def test_peer_receipt(self):
        bridge=await self.fixture(0)
        await bridge.marker('phone-A','123456',(1,2))
    async def test_denied(self):
        bridge=await self.fixture(1)
        with self.assertRaises(ValueError):await bridge.marker('phone-A','123456',(1,2))
    async def test_disconnected(self):
        bridge=await self.fixture(0)
        with self.assertRaises(ValueError):await bridge.marker('phone-B','123456',(1,2))


class Accessory(unittest.IsolatedAsyncioTestCase):
    async def test_connect_authenticate_send_and_reconfirm_after_reconnect(self):
        host = Bluetooth(lambda _: None)
        proc = SimpleNamespace(returncode=None, wait=AsyncMock(return_value=0),
                               stdin=Mock(drain=AsyncMock()), stdout=asyncio.StreamReader(),
                               stderr=asyncio.StreamReader())
        address = '01:23:45:67:89:AB'
        async def event(kind, **fields):
            proc.stdout.feed_data((json.dumps(dict(event=kind, **fields))+'\n').encode())
            await asyncio.sleep(0)
        with patch('asyncio.create_subprocess_exec', AsyncMock(return_value=proc)) as spawn:
            await host.connect_accessory(address)
        self.assertEqual(spawn.await_args.args[1:4], ('connect', '--device', address))
        self.assertNotIn('--latitude', spawn.await_args.args)
        await event('identification_accepted')
        self.assertFalse(host.ready)
        await event('authentication_succeeded')
        self.assertTrue(host.ready)
        proc.stdin.write.assert_not_called()
        await host.update_point(address, (22, 114), True, proc, 0)
        self.assertEqual(json.loads(proc.stdin.write.call_args.args[0]),
                         dict(latitude=22, longitude=114, jitter=True, generation=0))
        self.assertFalse(host.ready)
        await event('target_updated')
        self.assertTrue(host.ready)
        await event('reconnecting', generation=1)
        self.assertFalse(host.ready)
        await event('authentication_succeeded')
        await event('identification_accepted')
        with self.assertRaises(ValueError):
            await host.update_point(address, (23, 115), False, proc, 0)
        self.assertEqual(proc.stdin.write.call_count, 1)
        await host.update_point(address, (23, 115), False, proc, 1)
        await event('finished')
        proc.stdout.feed_eof()
        proc.stderr.feed_eof()
        await host.reader
        self.assertFalse(host.ready)
        self.assertIsNone(host.classic_id)

    async def test_accessory_recovery_binds_target_process_and_generation(self):
        host=Bluetooth(lambda _:None)
        proc=SimpleNamespace(returncode=None,stdin=Mock(),wait=AsyncMock(return_value=0))
        host.proc,host.classic_id,host.has_target,host.generation=proc,'selected',True,2
        for address,connection,generation in [('other',proc,2),('selected',object(),2),('selected',proc,1)]:
            with self.assertRaises(ValueError):
                await host.restore_accessory(address,connection,generation)
        proc.stdin.close.assert_not_called()
        await host.restore_accessory('selected',proc,2)
        proc.stdin.close.assert_called_once()
        proc.stdin.write.assert_not_called()
        self.assertIsNone(host.proc)
        self.assertFalse(host.has_target)

    async def test_ble_does_not_connect_on_send_or_use_replacement_client(self):
        host = Bluetooth(lambda _: None)
        with self.assertRaises(ValueError):
            await host.marker('phone','123456',(1,2))
        host.ble_id = 'phone'
        host.ble = SimpleNamespace(is_connected=True,write_gatt_char=AsyncMock())
        with self.assertRaises(ValueError):
            await host.marker('phone','123456',(1,2),object())
        host.ble.write_gatt_char.assert_not_awaited()

    async def test_refresh_does_not_start_reverse_advertising(self):
        bridge = Peripheral(Path('.'))
        with patch.object(bridge, 'start', AsyncMock()) as start:
            with self.assertRaises(ConnectionError):
                await bridge.peers()
            start.assert_not_awaited()
