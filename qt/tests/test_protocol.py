import asyncio
import datetime as dt
import struct
import sys
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock
from uuid import uuid4

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from core import ble_packet,merge_devices,point
from geo import project,unproject
from software import Software
from remote import Remote,read_frame,write_frame,tls_context,APPLE_EPOCH


class Formats(unittest.TestCase):
    def test_coordinates(self):
        for args in [(True,3),(1,181),(float('nan'),3),(float('inf'),4)]:
            with self.assertRaises(ValueError): point(*args)
        self.assertEqual(point(-90,180),(-90,180))

    def test_compact(self):
        self.assertEqual(ble_packet('012345',None),b'\x00012345')
        self.assertEqual(ble_packet('012345',(-1.0000005,2.0)),b'\x01012345'+struct.pack('>ii',-1000001,2000000))
        with self.assertRaises(ValueError):ble_packet('１２３４５６',None)

    def test_rmc(self):
        date=dt.datetime(2026,11,25,10,23,35,tzinfo=dt.timezone.utc)
        raw=ble_packet('123456',(23.5,-114.25),True,128,date)
        self.assertTrue(raw.startswith(b'\x02123456$GPRMC,102335,A,2330.00000,N,11415.00000,W,,,251126,,,S*'))
        self.assertEqual(raw[-2:],b'\r\n')
        self.assertEqual(ble_packet('123456',(23.5,-114.25),True,20,date)[0],1)

    def test_same_phone(self):
        rows=[SimpleNamespace(serial='AA-BB',connection_type='USB'),SimpleNamespace(serial='CC',connection_type='USB')]
        merged=merge_devices(rows,[dict(id='aabb',name='iPhone',network=True),dict(id='CC',name='iPhone',network=False)])
        self.assertEqual(len(merged),2)
        self.assertEqual(next(r for r in merged if r['id']=='AA-BB'),dict(id='AA-BB',name='iPhone',usb=True,wifi=True))

    def test_map_inverse(self):
        for a,b in [(23.129,113.264),(-23,113),(40,-70)]:
            x,y=project(a,b,16)
            c,d=unproject(x,y,16)
            self.assertAlmostEqual(a,c,9)
            self.assertAlmostEqual(b,d,9)


class Backend:
    def __init__(self):
        self.location=SimpleNamespace(set=AsyncMock(),clear=AsyncMock())
        self.tunnel=SimpleNamespace(rsd=True)
        self.opened=[]
    async def session(self,args,consumer):
        self.opened.append((args.udid,args.transport))
        await consumer(self.tunnel,self.location)


class Sessions(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.b=Backend()
        self.sw=Software(self.b)
        self.sw.visible={'aa':dict(id='AA',usb=True)}
        self.device=self.sw.get('AA')
        self.remote=Remote(self.sw,print)
        self.remote.key='1'*32
        self.remote.secret='2'*32
    async def asyncTearDown(self):
        if self.device.task and not self.device.task.done():
            self.device.stop.set()
            await self.device.task
    def req(self,action='apply',**fields):
        return dict(dict(id=str(uuid4()),action=action,device='AA',latitude=1,longitude=2,
                         session=self.device.revision,expires=time.time()-APPLE_EPOCH+30),**fields)

    async def test_set_change_restore(self):
        await self.device.execute((1,2),'USB')
        await self.device.execute((2,3),'USB')
        await self.device.execute(None,'USB')
        self.assertEqual(self.b.opened,[('AA','USB')])
        self.assertEqual(self.b.location.set.await_count,2)
        self.b.location.clear.assert_awaited_once()
        self.assertFalse(self.device.active)

    async def test_restore_existing_session_after_changing_transport(self):
        await self.device.execute((1, 2), 'USB')
        await self.device.execute(None, 'Network')
        self.assertEqual(self.b.opened, [('AA', 'USB')])
        self.b.location.clear.assert_awaited_once()

    async def test_cold_clear(self):
        await self.device.execute(None)
        self.b.location.clear.assert_awaited_once()

    async def test_uncertain(self):
        self.b.location.set.side_effect=ConnectionError()
        with self.assertRaises(ConnectionError):await self.device.execute((4,5))
        self.assertTrue(self.device.unknown)
        with self.assertRaises(ValueError):await self.device.execute((6,7))
        await self.device.execute(None)
        self.assertFalse(self.device.unknown)

    async def test_transport_disappears_while_opening(self):
        async def session(args, consumer):
            self.sw.visible['aa'] = dict(id='AA', wifi=True)
            await consumer(None, self.b.location)
        self.b.session = session
        with self.assertRaisesRegex(ValueError, '重新确认'):
            await self.device.execute((1,2), 'USB')
        self.b.location.set.assert_not_awaited()

    async def test_link_loss_invalidates_confirmation_and_requires_recovery(self):
        await self.device.execute((1,2))
        original = self.device.revision
        self.b.list_devices = AsyncMock(return_value=[])
        self.b.nearby = AsyncMock(return_value=dict(devices=[dict(id='AA', network=True)]))
        await self.sw.scan()
        self.assertTrue(self.device.unknown)
        self.assertNotEqual(original, self.device.revision)
        await self.device.task
        with self.assertRaises(ValueError):
            await self.device.execute((3,4), 'Network', revision=original)
        await self.device.execute(None, 'Network')
        self.assertEqual(self.b.opened, [('AA','USB'),('AA','Network')])
        self.assertFalse(self.device.unknown)

    async def test_unavailable_transport_never_opens_device(self):
        with self.assertRaises(ValueError):
            await self.device.execute((1,2), 'Network')
        self.assertFalse(self.b.opened)

    async def test_manual_address_is_reverified_for_same_device(self):
        self.sw.verify_address=AsyncMock(return_value=dict(id='AA', network=True, address='192.0.2.3'))
        self.b.list_devices=AsyncMock(return_value=[])
        self.b.nearby=AsyncMock(return_value=dict(devices=[]))
        self.assertEqual(await self.sw.use_address('192.0.2.3'), 'AA')
        rows,_=await self.sw.scan()
        self.sw.verify_address.assert_awaited_with('192.0.2.3','AA')
        self.assertEqual(rows[0]['address'], '192.0.2.3')
        self.sw.verify_address.side_effect=ConnectionError('unavailable')
        rows,_=await self.sw.scan()
        self.assertEqual(rows,[])

    async def test_remote_rejects_excessive_lifetime(self):
        result=await self.remote.handle(self.req(expires=time.time()-APPLE_EPOCH+120),'AA')
        self.assertEqual(result['phase'], 'rejected')
        self.b.location.set.assert_not_awaited()

    async def test_binding(self):
        unbound=await self.remote.handle(self.req('status'))
        self.assertEqual(unbound['targets'],[])
        bad=await self.remote.handle(self.req())
        self.assertEqual(bad['phase'],'rejected')
        status=await self.remote.handle(self.req('status'),'AA')
        g=status['grant']
        req=self.req(grant=g)
        self.assertEqual((await self.remote.handle(req))['phase'],'accepted')
        self.assertEqual((await self.remote.handle(self.req(device='BB',grant=g)))['phase'],'rejected')
        forged={'device':'BB','token':g['token']}
        self.assertIsNone(self.remote.bound(dict(grant=forged),None))

    async def test_concurrent_duplicates(self):
        req=self.req()
        replies=await asyncio.gather(*(self.remote.handle(req,'AA') for _ in range(3)))
        self.assertEqual([r['phase'] for r in replies],['accepted']*3)
        self.b.location.set.assert_awaited_once()
        conflict=await self.remote.handle(dict(req,latitude=55),'AA')
        self.assertEqual(conflict['phase'],'rejected')

    async def test_stale_expired(self):
        stale=self.req()
        expired=await self.remote.handle(self.req(expires=0),'AA')
        self.assertEqual(expired['phase'],'rejected')
        await self.device.execute((1,2))
        self.assertEqual((await self.remote.handle(stale,'AA'))['phase'],'rejected')
        self.b.location.set.assert_awaited_once()

    async def test_frame_limit(self):
        r=asyncio.StreamReader()
        r.feed_data(struct.pack('>I',1024*1024))
        with self.assertRaises(ValueError): await read_frame(r)

    async def test_tls_exchange(self):
        async def server(r,w):
            await write_frame(w,await read_frame(r))
            w.close()
        srv=await asyncio.start_server(server,'127.0.0.1',0,ssl=tls_context(self.remote.key,True))
        try:
            r,w=await asyncio.open_connection('127.0.0.1',srv.sockets[0].getsockname()[1],
                                              ssl=tls_context(self.remote.key,False),server_hostname='localhost')
            req=self.req('status')
            await write_frame(w,req)
            self.assertEqual(await read_frame(r),req)
            self.assertEqual(w.get_extra_info('cipher')[0],'PSK-AES128-GCM-SHA256')
            w.close()
            await w.wait_closed()
        finally:
            srv.close()
            await srv.wait_closed()
