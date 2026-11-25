"""Compatible with the existing iOS RemoteLink length-prefixed JSON / TLS-PSK protocol."""
import asyncio
import collections
import hashlib
import hmac
import json
import math
import plistlib
import secrets
import socket
import ssl
import struct
import time
from uuid import UUID

from core import device_key, point

LIMIT=256*1024
APPLE_EPOCH=978307200


def tls_context(key, server):
    if not getattr(ssl,'HAS_PSK',False):
        raise RuntimeError("当前 Python/OpenSSL 缺少 TLS-PSK 支持")
    ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER if server else ssl.PROTOCOL_TLS_CLIENT)
    ctx.minimum_version=ctx.maximum_version=ssl.TLSVersion.TLSv1_2
    ctx.set_ciphers('PSK-AES128-GCM-SHA256')
    if server:
        ctx.set_psk_server_callback(lambda identity:key.encode() if identity=='VirtualLocation/1' else b'')
    else:
        ctx.check_hostname=False
        ctx.verify_mode=ssl.CERT_NONE
        ctx.set_psk_client_callback(lambda hint:('VirtualLocation/1',key.encode()))
    return ctx


async def read_frame(r):
    (size,)=struct.unpack('>I',await r.readexactly(4))
    if not 0<size<=LIMIT:
        raise ValueError('遥控帧长度无效')
    req=json.loads(await r.readexactly(size))
    if not isinstance(req,dict):
        raise ValueError('遥控请求格式无效')
    UUID(req['id'])
    return req


async def write_frame(w,reply):
    data=json.dumps(reply,separators=(',',':')).encode()
    w.write(struct.pack('>I',len(data))+data)
    await w.drain()


async def usb_channel(serial):
    """Ask the local Apple service to open the specific physical device's loopback listener."""
    async def mux(cmd,w,r):
        fields=dict(MessageType=cmd.pop('MessageType'),ClientVersionString='Everywhere/1',
                    ProgName='Everywhere',kLibUSBMuxVersion=3,**cmd)
        body=plistlib.dumps(fields)
        w.write(struct.pack('<4I',16+len(body),1,8,1)+body)
        await w.drain()
        length,ver,kind,tag=struct.unpack('<4I',await r.readexactly(16))
        if not (16<length<=1024*1024 and (ver,kind,tag)==(1,8,1)):
            raise ValueError('Apple USB 服务响应无效')
        return plistlib.loads(await r.readexactly(length-16))
    r,w=await asyncio.open_connection('127.0.0.1',27015)
    try:
        rows=(await mux(dict(MessageType='ListDevices'),w,r))['DeviceList']
        ids=[row['DeviceID'] for row in rows if row['Properties'].get('ConnectionType')=='USB'
              and device_key(row['Properties'].get('SerialNumber',''))==device_key(serial)]
    finally:
        w.close()
        await w.wait_closed()
    if len(ids)!=1:
        raise ValueError('USB 未连接到所选 iPhone')
    r,w=await asyncio.open_connection('127.0.0.1',27015)
    try:
        res=await mux(dict(MessageType='Connect',DeviceID=ids[0],PortNumber=socket.htons(49371)),w,r)
        if res.get('Number')!=0:
            raise ConnectionError('请在手机开启 USB 接收')
    except BaseException:
        w.close()
        raise
    return r,w


class Remote:
    def __init__(self,software,report):
        self.software,self.report=software,report
        self.key=self.secret=self.server=self.usb=self.bonjour=None
        self.writers=set()
        self.tasks=set()
        self.receipts=collections.OrderedDict()
        self.locks={}

    async def credentials(self):
        import keyring
        def load():
            values=[]
            for account in ('remote-code','grant-secret'):
                v=keyring.get_password('Everywhere',account)
                if not v:
                    v=secrets.token_hex(16)
                    keyring.set_password('Everywhere',account,v)
                values.append(v)
            return values
        self.key,self.secret=await asyncio.to_thread(load)
        return self.key

    def grant(self,device):
        payload=(self.key+'|'+device_key(device)).encode()
        return hmac.new(bytes.fromhex(self.secret),payload,hashlib.sha256).hexdigest()[:32]

    def bound(self,req,usb):
        if usb:
            return usb
        g=req.get('grant') or {}
        dev,token=g.get('device'),g.get('token')
        if isinstance(dev,str) and 0<len(dev)<=64 and isinstance(token,str) and token.isascii():
            if hmac.compare_digest(token,self.grant(dev)):
                return dev
        return None

    def target(self,device):
        if not device:
            return []
        if device_key(device) not in self.software.visible and device_key(device) not in self.software.devices:
            return []
        s=self.software.get(device)
        return [dict(id=s.serial,session=s.revision,available=device_key(device) in self.software.visible,
                     needsClear=s.unknown,hasActiveLocation=s.active,recoveryScope='device',
                     detail='结果未知，请先恢复' if s.unknown else '会话已建立' if s.active else '等待设点')]

    async def handle(self,req,usb=None):
        device=self.bound(req,usb)
        def reply(phase,message):
            out=dict(id=req['id'],phase=phase,message=message,targets=self.target(device))
            if device: out['boundDevice']=device
            if usb: out['grant']=dict(device=usb,token=self.grant(usb))
            return out
        action=req['action']
        if action=='status':
            return reply('status','Windows 已连接')
        expires=req.get('expires')
        if type(expires) not in (int,float) or not math.isfinite(expires):
            return reply('rejected','无效的有效期')
        if not device or not isinstance(req.get('device'),str) or device_key(device)!=device_key(req['device']):
            return reply('rejected','需要先通过 USB 绑定本机')
        key=(device_key(device),str(UUID(req['id'])))
        fingerprint=(action,req.get('latitude'),req.get('longitude'),req.get('session'))
        lock=self.locks.setdefault(key[0],asyncio.Lock())
        async with lock:
            cached=self.receipts.get(key)
            if cached:
                return cached[1] if cached[0]==fingerprint else reply('rejected','请求 ID 已被使用')
            if not 0 <= expires + APPLE_EPOCH - time.time() <= 60:
                return reply('rejected','请求已过期或有效期超过 60 秒')
            try:
                expected=str(UUID(req['session']))
                if action not in ('apply','clear'):
                    raise ValueError('未知指令')
                coords=point(req['latitude'],req['longitude']) if action=='apply' else None
                await self.software.get(device).execute(coords,revision=expected,deadline=expires+APPLE_EPOCH)
                result=reply('accepted','开发服务已返回，请在手机诊断页核对新样本')
            except (ValueError,KeyError,TypeError) as exc:
                result=reply('rejected',str(exc))
            except Exception as exc:
                result=reply('unknown',str(exc))
            self.receipts[key]=(fingerprint,result)
            if len(self.receipts)>1024: self.receipts.popitem(last=False)
            return result

    async def peer(self,r,w,usb=None):
        self.writers.add(w)
        task=asyncio.current_task()
        self.tasks.add(task)
        try:
            while True:
                req=await asyncio.wait_for(read_frame(r),180)
                if req.get('action')!='status':
                    await write_frame(w,dict(id=req['id'],phase='delivered',message='主机已收到请求',targets=[]))
                await write_frame(w,await self.handle(req,usb))
        except (OSError,asyncio.IncompleteReadError,ValueError,KeyError,TimeoutError):
            pass
        finally:
            self.tasks.discard(task)
            self.writers.discard(w)
            w.close()

    async def start_network(self,port):
        if self.server: raise ValueError('网络遥控已开启')
        await self.credentials()
        server=await asyncio.start_server(self.peer,port=port,ssl=tls_context(self.key,True),ssl_handshake_timeout=10)
        self.server=server
        from zeroconf import ServiceInfo
        from zeroconf.asyncio import AsyncZeroconf
        import ipaddress
        try:
            host=socket.gethostname()
            addresses=[ipaddress.ip_address(i[4][0]).packed for i in socket.getaddrinfo(host,None,socket.AF_INET)
                       if not i[4][0].startswith('127.')]
            info=ServiceInfo('_vloc-remote._tcp.local.',f'{host}._vloc-remote._tcp.local.',port=port,
                             addresses=addresses,server=host+'.local.')
            self.bonjour=AsyncZeroconf()
            await self.bonjour.async_register_service(info,allow_name_change=True)
        except Exception:
            self.report('Bonjour 广播失败，可在手机手动输入主机地址')
        return self.key

    async def start_usb(self,serial):
        if self.usb: raise ValueError('USB 遥控已开启')
        if not self.software.visible.get(device_key(serial),{}).get('usb'):
            raise ValueError('请选择通过 USB 接入的设备')
        await self.credentials()
        context=tls_context(self.key,False)
        async def run():
            last=''
            while True:
                w=None
                try:
                    r,w=await asyncio.wait_for(usb_channel(serial),8)
                    await w.start_tls(context,server_hostname='localhost',ssl_handshake_timeout=8)
                    self.report('USB 遥控已连接')
                    await self.peer(r,w,serial)
                except (ValueError,OSError,TimeoutError,asyncio.IncompleteReadError) as exc:
                    if str(exc)!=last:
                        self.report('USB 遥控等待连接 · '+str(exc))
                        last=str(exc)
                finally:
                    if w: w.close()
                await asyncio.sleep(2)
        self.usb=asyncio.create_task(run())
        return self.key

    async def stop(self):
        server,self.server=self.server,None
        if server:
            server.close()
        if self.bonjour:
            await self.bonjour.async_unregister_all_services()
            await self.bonjour.async_close()
            self.bonjour=None
        if self.usb:
            self.usb.cancel()
            await asyncio.gather(self.usb,return_exceptions=True)
            self.usb=None
        for w in list(self.writers): w.close()
        await asyncio.gather(*list(self.tasks),return_exceptions=True)
        if server:
            await server.wait_closed()

    async def revoke(self):
        import keyring
        await self.stop()
        for account in ('remote-code','grant-secret'):
            if await asyncio.to_thread(keyring.get_password,'Everywhere',account):
                await asyncio.to_thread(keyring.delete_password,'Everywhere',account)
        self.receipts.clear()
        self.key=self.secret=None
