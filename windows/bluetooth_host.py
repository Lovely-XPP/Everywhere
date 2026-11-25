import asyncio
import json
import os
from pathlib import Path
import subprocess
import sys

from core import SERVICE, COMMAND, RMC, ble_packet

NO_WINDOW = getattr(subprocess, 'CREATE_NO_WINDOW', 0)


class Bluetooth:
    def __init__(self, report, bundle=None, changed=None):
        self.report = report
        self.changed = changed or (lambda: None)
        self.identified = self.authenticated = self.updating = False
        self.bundle = bundle or Path(sys.executable).parent
        self.ble = self.proc = self.reader = None
        self.ble_id = self.classic_id = None
        self.generation = 0
        self.peers = {}

    async def scan(self, mode):
        if mode in ('classic', 'nearby'):
            proc = await asyncio.create_subprocess_exec(str(self.bundle/'rfcomm.exe'), '--discover' if mode == 'nearby' else '--list',
                    stdout=asyncio.subprocess.PIPE, creationflags=NO_WINDOW)
            out, _ = await proc.communicate()
            if proc.returncode:
                raise RuntimeError("无法读取经典蓝牙适配器，请检查 Windows 蓝牙设置")
            rows = [s.split('\t',1) for s in out.decode('utf-8','replace').splitlines()]
            return [dict(id=v[0],name=v[-1]) for v in rows if len(v)==2]
        from bleak import BleakScanner
        self.peers = {p.address:p for p in await BleakScanner.discover(timeout=4,service_uuids=[SERVICE])}
        return [dict(id=addr,name=p.name or addr) for addr,p in self.peers.items()]

    async def connect_ble(self, address):
        from bleak import BleakClient
        await self.disconnect_ble()
        if address not in self.peers:
            raise ValueError("请重新扫描并选择手机")

        def disconnected(client):
            if client is self.ble:
                self.ble = self.ble_id = None
                self.report("手机蓝牙接收服务已断开")
                self.changed()

        client = BleakClient(self.peers[address], timeout=20, disconnected_callback=disconnected)
        self.ble = client
        try:
            await client.connect()
            field = client.services.get_characteristic(COMMAND)
            if not field or 'write' not in field.properties:
                raise ValueError("手机没有提供带回执的定位特征")
            if 'notify' in field.properties:
                await client.start_notify(field, lambda *_: None)
            if self.ble is not client or not client.is_connected:
                raise ConnectionError("蓝牙连接已断开")
            self.ble_id = address
        except BaseException:
            await self.disconnect_ble()
            raise
        self.changed()

    async def marker(self, address, code, coords, connection=None):
        client = self.ble
        if (not client or not client.is_connected or self.ble_id != address
                or connection is not None and connection is not client):
            raise ValueError("请先连接所选手机")
        packet = ble_packet(code, coords, client.services.get_characteristic(RMC) is not None,
                            max(20, client.mtu_size - 3))
        await client.write_gatt_char(COMMAND, packet, response=True)

    async def disconnect_ble(self):
        client = self.ble
        self.ble = self.ble_id = None
        if client:
            await client.disconnect()
        self.changed()

    @property
    def ready(self):
        return bool(self.proc and self.proc.returncode is None and self.identified
                    and self.authenticated and not self.updating)

    async def connect_accessory(self, address):
        if self.proc and self.proc.returncode is None:
            raise ValueError("请先结束现有 iAP2 会话")
        if self.reader:
            await self.reader
        self.generation = 0
        self.identified = self.authenticated = self.updating = False
        worker = str(self.bundle / 'EverywhereWorker.exe')
        self.proc = await asyncio.create_subprocess_exec(
            worker, 'connect', '--device', address, '--bluetooth-helper', str(self.bundle / 'rfcomm.exe'),
            '--auth-helper', os.environ.get('EVERYWHERE_AUTH_PROVIDER', worker),
            stdout=asyncio.subprocess.PIPE, stdin=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            creationflags=NO_WINDOW, env={**os.environ, "PYTHONIOENCODING": "utf-8"})
        self.classic_id = address
        self.reader = asyncio.create_task(self.watch(self.proc))
        self.changed()

    async def update_point(self, address, coords, jitter, connection, generation):
        if not self.ready or self.proc is not connection or self.generation != generation or address != self.classic_id:
            raise ValueError("连接已变化，请重新确认选点")
        lat, lon = coords
        self.updating = True
        try:
            self.proc.stdin.write((json.dumps(dict(latitude=lat, longitude=lon, jitter=jitter,
                                                   generation=generation)) + '\n').encode())
            await self.proc.stdin.drain()
        except BaseException:
            self.updating = False
            raise

    async def watch(self, proc):
        try:
            await self.read_events(proc)
        finally:
            if self.proc is proc:
                self.identified = self.authenticated = self.updating = False
                self.classic_id = None
                self.changed()

    async def read_events(self, proc):
        labels={'rfcomm_connected':'RFCOMM 已连接','link_ready':'iAP2 链路就绪',
                'identification_accepted':'已接受配件标识','authentication_succeeded':'iPhone 已接受配件认证',
                'location_requested':'手机已请求位置','location_stopped':'手机已停止请求位置',
                'reconnecting':'连接中断，正在重连','reconnected':'已重连，请重新确认选点',
                'target_updated':'选点已更新','finished':'iAP2 会话已结束'}
        error_task=asyncio.create_task(proc.stderr.read())
        while line:=await proc.stdout.readline():
            try:
                row=json.loads(line.decode('utf-8','replace'))
            except ValueError:
                continue
            kind=row.get('event')
            if kind=='reconnecting':
                self.generation=row['generation']
                self.identified = self.authenticated = self.updating = False
            elif kind == 'identification_accepted':
                self.identified = True
            elif kind == 'authentication_succeeded':
                self.authenticated = True
            elif kind == 'target_updated':
                self.updating = False
            elif kind in ('error', 'finished'):
                self.identified = self.authenticated = False
            if kind in ('identification_accepted', 'authentication_succeeded', 'target_updated', 'reconnecting', 'finished', 'error'):
                self.changed()
            if kind=='location_link_acknowledged':
                self.report(f"链路回执 {row['count']} · {row['latitude']:.7f}, {row['longitude']:.7f}")
            elif kind=='error':
                self.report(row.get('detail','iAP2 错误'))
            elif kind in labels:
                self.report(labels[kind])
        error=(await error_task).decode(errors='replace').strip()
        if await proc.wait():
            self.report(error[-240:] or 'iAP2 会话异常结束，请核对手机样本')

    async def stop(self):
        if self.proc and self.proc.returncode is None:
            self.proc.stdin.close()
            try:
                await asyncio.wait_for(self.proc.wait(),6)
            except TimeoutError:
                self.proc.terminate()
                await self.proc.wait()
        if self.reader:
            await self.reader
        self.proc=self.reader=None
        await self.disconnect_ble()
