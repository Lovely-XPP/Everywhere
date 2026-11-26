"""异步调用同一项目的 CoreBluetooth 后端，每条请求关联到当前进程和已选设备。"""
import asyncio
import json


class MacBluetooth:
    def __init__(self, bundle):
        self.executable = str(bundle / 'QtBluetoothBridge')
        self.proc = None
        self.lock = asyncio.Lock()

    async def read(self):
        raw = await asyncio.wait_for(self.proc.stdout.readline(), 40)
        if not raw:
            raise ConnectionError('Mac 蓝牙会话已结束')
        reply = json.loads(raw)
        if 'error' in reply:
            raise RuntimeError(reply['error'])
        return reply

    async def open(self, *args):
        self.proc = await asyncio.create_subprocess_exec(self.executable, *args,
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE)
        try:
            reply = await self.read()
            if args[0] != 'scan' and not reply.get('ready'):
                raise ConnectionError('Mac 蓝牙尚未就绪')
            return reply
        except BaseException:
            await self.stop()
            raise

    async def start(self, status=False):
        if not self.proc or self.proc.returncode is not None:
            await self.open('status' if status else 'markers')

    async def request(self, op, **fields):
        async with self.lock:
            if not self.proc or self.proc.returncode is not None:
                raise ConnectionError('蓝牙连接已断开')
            try:
                self.proc.stdin.write(json.dumps(dict(op=op, **fields)).encode() + b'\n')
                await self.proc.stdin.drain()
                return await self.read()
            except (TimeoutError, OSError, asyncio.CancelledError):
                # A delayed reply cannot be associated with a subsequent request.
                await self.stop()
                raise

    async def peers(self):
        return {key.encode().hex(): {} for key in (await self.request('peers'))['peers']}

    async def marker(self, device, code, coords, connection=None):
        if connection is not None and self.proc is not connection:
            raise ConnectionError('蓝牙会话已变化')
        await self.request('marker', id=bytes.fromhex(device).decode(), code=code, coords=coords)

    async def update(self, target, authenticated, message):
        await self.request('status', target=target[:24], authenticated=authenticated, message=message[:80])

    async def stop(self):
        proc, self.proc = self.proc, None
        if proc and proc.returncode is None:
            proc.stdin.close()
            try:
                await asyncio.wait_for(proc.wait(), 3)
            except TimeoutError:
                proc.kill()
                await proc.wait()
