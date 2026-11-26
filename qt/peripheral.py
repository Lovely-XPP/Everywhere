"""Select one subscribed phone and correlate its five-byte application receipt."""
import asyncio
import json
import secrets
from host_platform import binary
from bluetooth_host import NO_WINDOW
from core import ble_packet


class Peripheral:
    def __init__(self,bundle):
        self.program=binary(bundle,'EverywhereGatt')
        self.proc=None
        self.lock=asyncio.Lock()

    async def start(self,status=False):
        if self.proc and self.proc.returncode is None:
            return
        self.proc=await asyncio.create_subprocess_exec(str(self.program),'status' if status else 'markers',
                    stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,creationflags=NO_WINDOW)
        try:
            if await self.line()!='READY': raise ConnectionError('未能开启蓝牙广播')
        except BaseException:
            await self.stop()
            raise

    async def command(self,line):
        self.proc.stdin.write((line+'\n').encode())
        await self.proc.stdin.drain()

    async def line(self):
        raw=await asyncio.wait_for(self.proc.stdout.readline(),12)
        if not raw: raise ConnectionError('GATT 服务已关闭')
        msg=raw.decode('utf8','replace').strip()
        if msg.startswith('ERROR'): raise RuntimeError(msg)
        return msg

    async def peers(self):
        async with self.lock:
            if self.proc is None or self.proc.returncode is not None:
                raise ConnectionError('请先开启电脑蓝牙广播')
            await self.command('PEERS')
            peers={}
            while (line:=await self.line())!='END':
                if line.startswith('PEER '):
                    _,device,kind,cap=line.split()
                    peers.setdefault(device,{})[kind]=int(cap)
            return peers

    async def marker(self,device,code,coords,connection=None):
        peers=await self.peers()
        if device not in peers:
            raise ValueError('请选择已订阅的手机')
        caps=peers[device]
        # 新版 iPhone 可仅订阅 RMC 特征，紧凑载荷同样通过已订阅的特征发送。
        minimum=11 if coords is None else 19
        kind='R' if caps.get('R',0)>=minimum else 'C'
        if caps.get(kind,0)<minimum:
            raise ValueError('手机订阅的蓝牙特征容量不足')
        packet=ble_packet(code,coords,kind=='R',caps[kind]-4)
        nonce=secrets.token_bytes(4)
        async with self.lock:
            if connection is not None and self.proc is not connection:
                raise ConnectionError('蓝牙广播连接已变化，请重新确认')
            await self.command(f'SEND {device} {kind} {(nonce+packet).hex()}')
            async with asyncio.timeout(12):
                while True:
                    parts=(await self.line()).split()
                    if len(parts)==3 and parts[:2]==['ACK',device]:
                        ack=bytes.fromhex(parts[2])
                        if len(ack)==5 and ack[:4]==nonce:
                            if ack[4]: raise ValueError('手机拒绝了命令，请检查接收码')
                            return

    async def update(self,target,authenticated,message):
        if self.proc and self.proc.returncode is None:
            data=json.dumps(dict(target=target[:24],authenticated=authenticated,message=message[:80]),
                            ensure_ascii=False).encode()
            await self.command('STATUS '+data.hex())

    async def stop(self):
        if self.proc and self.proc.returncode is None:
            self.proc.stdin.close()
            try:
                await asyncio.wait_for(self.proc.wait(),3)
            except TimeoutError:
                self.proc.kill()
                await self.proc.wait()
        self.proc=None
