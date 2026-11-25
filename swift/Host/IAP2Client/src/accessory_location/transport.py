import asyncio
import re

from .wire import DETECT, ProtocolError


def bluetooth_address(text):
    if not re.fullmatch(r"(?:[0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}", text):
        raise ValueError("Expected a six-byte Bluetooth address")
    return bytes.fromhex(text.replace(":", "").replace("-", ""))


class BluetoothStream:
    def __init__(self, process):
        self.process = process
        self.cached_channel = False

    @classmethod
    async def open(cls, executable, address, emit=None, *, live_only=False):
        bluetooth_address(address)
        process = await asyncio.create_subprocess_exec(
            executable,
            *(["--live"] if live_only else []),
            address,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stream = cls(process)
        try:
            await asyncio.wait_for(stream._wait_open(emit), 110)
            return stream
        except BaseException:
            await stream.close()
            raise

    async def _wait_open(self, emit):
        # Only relay records produced by our bridge; system logs may contain device identifiers.
        diagnostic = ""
        while line := await self.process.stderr.readline():
            line = line.decode(errors="replace").strip()
            if line in {"EW_PHASE baseband", "EW_PHASE discovery", "EW_PHASE open"}:
                if emit is not None:
                    emit(event="bluetooth_stage", stage=line.split()[1])
                continue
            if line in {"EW_OPEN_READY", "EW_OPEN_READY cache"}:
                self.cached_channel = line.endswith(" cache")
                return
            if re.fullmatch(r"EW_OPEN_ERROR channel=\d{1,2} status=0x[0-9a-f]{8} record=(live|cache) cause=(busy|permission|timeout|other)", line):
                diagnostic = line
            elif re.fullmatch(r"EW_(?:BASEBAND|SDP)_ERROR status=0x[0-9a-f]{8}", line):
                diagnostic = line
        code = await self.process.wait()
        reasons = {2: "Selected device is not paired", 3: "Bluetooth service discovery failed",
                   4: "RFCOMM open failed", 6: "iAP2 service unavailable", 8: "Bluetooth target unavailable"}
        raise RuntimeError(diagnostic or reasons.get(code, "Bluetooth bridge stopped before RFCOMM opened"))

    @classmethod
    async def open_detected(cls, executable, address, emit):
        """缓存通道打开或协议检测失败时，释放该桥并对同一设备实时查询一次。"""
        for live_only in (False, True):
            try:
                stream = await cls.open(executable, address, emit, live_only=live_only)
            except RuntimeError as error:
                if not live_only and str(error).startswith("EW_OPEN_ERROR ") and "record=cache" in str(error).split():
                    continue
                raise
            try:
                emit(event="rfcomm_connected")
                await stream.detect()
                return stream
            except (EOFError, ConnectionError, TimeoutError, ProtocolError):
                await stream.close()
                if live_only or not stream.cached_channel:
                    raise
            except BaseException:
                await stream.close()
                raise

    async def detect(self):
        await self.sendall(DETECT)
        response = await asyncio.wait_for(self.recvall(6), 20)
        if response != DETECT:
            raise ProtocolError(f"Unexpected iAP2 detection response: {response.hex()}")

    async def recvall(self, size):
        return await self.process.stdout.readexactly(size)

    async def sendall(self, data):
        self.process.stdin.write(data)
        await self.process.stdin.drain()

    async def close(self):
        self.process.stdin.close()
        try:
            await asyncio.wait_for(self.process.wait(), 2)
        except TimeoutError:
            if self.process.returncode is None:
                self.process.terminate()
            try:
                await asyncio.wait_for(self.process.wait(), 2)
            except TimeoutError:
                self.process.kill()
                await self.process.wait()


async def controller_address(executable):
    process = await asyncio.create_subprocess_exec(
        executable,
        "--controller",
        stdout=asyncio.subprocess.PIPE,
    )
    try:
        stdout, _ = await asyncio.wait_for(process.communicate(), 10)
    except TimeoutError:
        process.kill()
        await process.wait()
        raise
    if process.returncode:
        raise RuntimeError("Unable to read the local Bluetooth controller address")
    return bluetooth_address(stdout.decode().strip())
