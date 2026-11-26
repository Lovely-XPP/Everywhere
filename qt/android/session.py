"""Android 经典蓝牙传输。配件身份和 iAP2 协议均在安卓本机执行。"""
import asyncio
import json
from pathlib import Path
from types import SimpleNamespace

from accessory_location.cli import Delivery, exchange
from accessory_location.link import Link
from accessory_location.transport import BluetoothStream, bluetooth_address
from accessory_location.wire import Message, parameter

IAP2_SERVICE = "00000000-deca-fade-deca-deafdecacafe"


def adapter():
    """返回已开启的系统蓝牙适配器。调用方须先取得附近设备权限。"""
    from jnius import autoclass
    radio = autoclass("android.bluetooth.BluetoothAdapter").getDefaultAdapter()
    if radio is None or not radio.isEnabled():
        raise RuntimeError("请先在 Android 系统设置中打开经典蓝牙。")
    return radio


def paired_devices():
    """列出 Android 已配对设备；系统隐藏本机蓝牙地址时留空。"""
    from jnius import cast
    radio = adapter()
    devices = []
    for item in radio.getBondedDevices().toArray():
        device = cast("android.bluetooth.BluetoothDevice", item)
        address = str(device.getAddress())
        devices.append((str(device.getName() or address), address))
    try:
        address = str(radio.getAddress() or "")
        local_address(address)
    except Exception:
        address = ""
    return sorted(devices), address


def local_address(value):
    """校验用于配件识别的本机经典蓝牙地址，拒绝 Android 隐私占位值。"""
    raw = bluetooth_address(value.strip())
    if raw in (bytes(6), bytes.fromhex("020000000000"), bytes([255]) * 6):
        raise ValueError("请输入 Android 手机真实的蓝牙地址。")
    return raw


class AccessoryIdentity:
    """读取本地构建所携带的 MFi 身份，只签署 32 字节的配件挑战。"""
    def __init__(self, directory):
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric import ec
        from cryptography.hazmat.primitives.serialization.pkcs7 import load_der_pkcs7_certificates
        self.container = (directory / "certificate.p7b").read_bytes()
        self.key = serialization.load_der_private_key((directory / "identity.pk8").read_bytes(), None)
        if not isinstance(self.key, ec.EllipticCurvePrivateKey) or not isinstance(self.key.curve, ec.SECP256R1):
            raise ValueError("配件身份需要 P-256 私钥。")
        if not any(cert.public_key() == self.key.public_key() for cert in load_der_pkcs7_certificates(self.container)):
            raise ValueError("配件证书与私钥不匹配。")

    async def certificate(self):
        return Message(0xAA01, parameter(0, self.container))

    async def sign(self, digest):
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.asymmetric import ec, utils
        if len(digest) != 32:
            raise ValueError("配件认证挑战长度无效。")
        der = self.key.sign(digest, ec.ECDSA(utils.Prehashed(hashes.SHA256())))
        raw = b"".join(part.to_bytes(32, "big") for part in utils.decode_dss_signature(der))
        return Message(0xAA03, parameter(0, raw))


class AndroidStream:
    """以 Android 安全 RFCOMM socket 提供异步字节流。关闭 socket 会唤醒阻塞读写。"""
    def __init__(self, device):
        from jnius import autoclass
        service = autoclass("java.util.UUID").fromString(IAP2_SERVICE)
        self.socket = adapter().getRemoteDevice(device).createRfcommSocketToServiceRecord(service)

    async def open(self):
        from jnius import autoclass
        await asyncio.wait_for(asyncio.to_thread(self.socket.connect), 35)
        self.reader = autoclass("java.io.DataInputStream")(self.socket.getInputStream())
        self.writer = self.socket.getOutputStream()

    async def recvall(self, size):
        def read():
            data = bytearray(size)
            self.reader.readFully(data, pass_by_reference=True)
            return bytes(data)
        return await asyncio.to_thread(read)

    async def sendall(self, data):
        await asyncio.wait_for(asyncio.to_thread(self.writer.write, bytearray(data), 0, len(data)), 15)

    async def close(self):
        await asyncio.to_thread(self.socket.close)


async def run_session(device, address, emit, read_update):
    """在工作线程的事件循环中运行一个前台会话；取消会关闭连接且不会重发旧坐标。"""
    local = local_address(address)
    auth = AccessoryIdentity(Path(__file__).resolve().parent / "mfi")
    stream = AndroidStream(device)
    link = Link(stream, emit)
    try:
        await stream.open()
        emit(event="rfcomm_connected")
        await BluetoothStream.detect(stream)
        args = SimpleNamespace(command="connect", until_stopped=True, stdin_updates=True,
                               transport="bluetooth", interval=1.0, jitter=False)
        await exchange(args, 0, Delivery(), link, auth, local, emit, lambda: True, read_update)
    finally:
        await link.close()


def target_command(latitude, longitude):
    return json.dumps(dict(latitude=latitude, longitude=longitude), allow_nan=False).encode() + b"\n"
