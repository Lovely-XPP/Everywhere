"""Keep the same developer service open from set to clear. Only the chosen UDID may receive commands."""
import asyncio
import time
from types import SimpleNamespace
from uuid import uuid4

from core import device_key, merge_devices, point


class Software:
    def __init__(self, backend=None):
        self.backend = backend
        self.devices = {}
        self.visible = {}
        self.wifi_address = None

    def provider(self):
        if self.backend is None:
            import portable_location
            self.backend = portable_location
        return self.backend

    async def verify_address(self, address, expected=None):
        async with await self.provider().wireless_target(address, expected) as client:
            return dict(id=client.udid, name=client.short_info.get('DeviceName') or client.udid,
                        network=True, address=address)

    async def use_address(self, address):
        row = await self.verify_address(address)
        self.wifi_address = (address, row['id'])
        return row['id']

    async def scan(self):
        backend = self.provider()
        mux, details = await asyncio.gather(asyncio.wait_for(backend.list_devices(), 5),
                                           asyncio.wait_for(backend.nearby(), 12), return_exceptions=True)
        warnings = []
        if isinstance(mux, Exception):
            warnings.append("无法读取 Apple USB 设备服务，请检查数据线及系统的 Apple 设备服务或 usbmuxd")
            mux = []
        if isinstance(details, Exception):
            warnings.append("Wi-Fi 设备查询失败")
            details = {}
        if details.get('warning'):
            warnings.append("局域网发现受限，请检查网络与防火墙")
        direct = None
        if self.wifi_address:
            try:
                direct = await self.verify_address(*self.wifi_address)
            except Exception as exc:
                warnings.append('未确认手动 Wi-Fi 地址 · '+str(exc))
        rows = merge_devices(mux, [*details.get('devices', []), *([direct] if direct else [])])
        if direct:
            for row in rows:
                if device_key(row['id']) == device_key(direct['id']):
                    row['address'] = direct['address']
        visible = {device_key(row['id']):row for row in rows if row['usb'] or row['wifi']}
        for key, old in self.visible.items():
            session = self.devices.get(key)
            new = visible.get(key, {})
            if session and any(old.get(k) and not new.get(k) for k in ('usb', 'wifi')):
                # Invalidate outstanding confirmations even when the other transport survives.
                session.revision = str(uuid4())
                if not session.task or session.task.done() or session.available(session.link, new):
                    continue
                if session.active:
                    session.unknown = True
                session.stop.set()
        self.visible = visible
        for row in visible.values():
            self.get(row['id'])
        return list(visible.values()), '；'.join(warnings)

    def get(self, serial):
        key = device_key(serial)
        if key not in self.visible and key not in self.devices:
            raise ValueError("请先刷新并选择设备")
        if key not in self.devices:
            self.devices[key] = Session(self.visible[key]['id'], self.provider(), lambda: self.visible.get(key))
        return self.devices[key]

    async def prepare(self, serial):
        target = self.get(serial)
        if not self.visible.get(device_key(serial), {}).get('usb'):
            raise ValueError("请先用 USB 接入并在手机上确认信任")
        async with target.lock:
            await asyncio.wait_for(self.provider().session(SimpleNamespace(
                udid=target.serial, transport="USB", prepare_wifi=True)), 65)


class Session:
    def __init__(self, serial, backend, connected):
        self.serial, self.backend, self.connected = serial, backend, connected
        self.lock = asyncio.Lock()
        self.task = self.location = None
        self.active = self.unknown = False
        self.revision = str(uuid4())

    @staticmethod
    def available(link, row):
        return bool((link in ('auto', 'USB') and row.get('usb')) or
                    (link in ('auto', 'Network') and row.get('wifi')))

    async def open(self, link):
        if self.task and not self.task.done() and self.stop.is_set():
            await asyncio.gather(self.task, return_exceptions=True)
        if self.task and not self.task.done():
            if link != 'auto' and link != self.link:
                raise ValueError("请先恢复定位，再切换执行链路")
            return
        self.link = link
        self.stop = asyncio.Event()
        ready = asyncio.Event()
        async def consume(tunnel, location):
            self.location = location
            ready.set()
            try:
                while not self.stop.is_set():
                    if tunnel and tunnel.rsd is None:
                        raise ConnectionError("开发隧道已断开")
                    try:
                        await asyncio.wait_for(self.stop.wait(), 1)
                    except TimeoutError:
                        pass
            finally:
                self.location = None
                if self.active:
                    self.unknown = True
                    self.revision = str(uuid4())
        args = SimpleNamespace(udid=self.serial, transport=link, prepare_wifi=False,
                               address=(self.connected() or {}).get('address') if link == 'Network' else None)
        self.task = asyncio.create_task(self.backend.session(args, consumer=consume))
        self.task.add_done_callback(lambda t: None if t.cancelled() else t.exception())
        waiter = asyncio.create_task(ready.wait())
        try:
            done, _ = await asyncio.wait((self.task, waiter), timeout=120, return_when=asyncio.FIRST_COMPLETED)
            if self.task in done:
                await self.task
                raise ConnectionError("设备会话提前结束")
            if not done:
                raise TimeoutError("设备准备超时，请检查信任、开发者模式和开发镜像")
        except BaseException:
            self.task.cancel()
            await asyncio.gather(self.task, return_exceptions=True)
            raise
        finally:
            waiter.cancel()
            await asyncio.gather(waiter, return_exceptions=True)

    async def execute(self, coords, link='auto', revision=None, deadline=None):
        if coords is not None:
            coords = point(*coords)
        async with self.lock:
            if deadline is not None and time.time()>deadline:
                raise ValueError('遥控请求已过期')
            if revision is not None and self.revision != revision:
                raise ValueError("设备会话已变化，请刷新")
            row = self.connected() or {}
            if coords is not None and not self.available(link, row):
                raise ValueError("所选设备未通过指定链路连接")
            if link == 'auto' and (not self.task or self.task.done()) and row:
                link = 'USB' if row.get('usb') else 'Network'
            if coords is not None and self.unknown:
                raise ValueError("上一次操作结果未知，请先恢复定位")
            # 恢复优先沿用已有会话；失联后才按用户所选链路重新连接。
            if coords is None and self.task and not self.task.done() and not self.stop.is_set():
                link = self.link
            await self.open(link)
            if coords is not None and (not self.available(self.link, self.connected() or {}) or self.stop.is_set() or self.unknown or
                                       revision is not None and self.revision != revision):
                if not self.active:
                    self.stop.set()
                    await asyncio.gather(self.task, return_exceptions=True)
                raise ValueError("准备期间目标连接已变化，请重新确认")
            if deadline is not None and time.time()>deadline:
                if not self.active:
                    self.stop.set()
                    await asyncio.gather(self.task, return_exceptions=True)
                raise ValueError('请求在设备准备期间过期')
            self.revision = str(uuid4())
            self.active = self.unknown = True
            try:
                call = self.location.clear() if coords is None else self.location.set(*coords)
                await asyncio.wait_for(call, 20)
                if self.stop.is_set() or self.location is None:
                    raise ConnectionError('调用期间设备连接已断开，定位结果未知，请重新连接并恢复')
                self.active = coords is not None
                self.unknown = False
            finally:
                if self.unknown or not self.active:
                    self.stop.set()
                    await asyncio.gather(self.task, return_exceptions=True)
