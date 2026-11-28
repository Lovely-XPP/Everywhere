import argparse
import asyncio
import json
import math
import os
import select
import sys
from dataclasses import dataclass

from .auth import AuthenticationProvider
from .link import Link
from .profile import coordinate, identity, jittered_point, location_message, location_sentences
from .transport import BluetoothStream, controller_address
from .wire import parameters


def emit(**event):
    print(json.dumps(event, ensure_ascii=False), flush=True)


@dataclass
class Delivery:
    count: int = 0


def transient_link_failure(error):
    """仅对传输中断和明确的临时系统错误重建链路。"""
    if isinstance(error, (EOFError, ConnectionError, TimeoutError)):
        return True
    detail = str(error)
    if detail.startswith(("EW_WINDOWS_RFCOMM_ERROR ", "EW_WINDOWS_SDP_ERROR ")):
        return detail.split()[-1] in {"status=10051", "status=10053", "status=10054", "status=10060"}
    if not detail.startswith(("EW_BASEBAND_ERROR ", "EW_SDP_ERROR ", "EW_OPEN_ERROR ")):
        return False
    transient = {"status=0xe00002c5", "status=0xe00002cd", "status=0xe00002d5",
                 "status=0xe00002d6", "status=0xe00002d7", "status=0xe00002ed"}
    return bool(transient.intersection(detail.split()))


async def run(args):
    parent = os.getppid()
    delivery = Delivery()
    persistent = args.until_stopped and getattr(args, "stdin_updates", False)
    for generation in range(3):
        try:
            return await run_connection(args, parent, generation, delivery)
        except Exception as error:
            if not persistent or generation == 2 or not transient_link_failure(error):
                raise
            if os.getppid() != parent:
                return
            delay = (2, 5)[generation]
            emit(event="reconnecting", generation=generation + 1, delay=delay,
                 needs_confirmation=True)
            await asyncio.sleep(delay)
            if os.getppid() != parent:
                return


def pending_input():
    """Windows 的 select 只接受 socket；通过匿名管道句柄查询输入或 EOF。"""
    if os.name != "nt":
        return bool(select.select([0], [], [], 0)[0])
    import ctypes
    import msvcrt
    from ctypes import wintypes
    count = wintypes.DWORD()
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    if not kernel.PeekNamedPipe(wintypes.HANDLE(msvcrt.get_osfhandle(0)), None, 0, None, ctypes.byref(count), None):
        if ctypes.get_last_error() in (109, 232):
            return True
        raise ctypes.WinError(ctypes.get_last_error())
    return count.value > 0


async def run_connection(args, parent, generation, delivery):
    """每次使用新的 RFCOMM、认证程序、协商序列号与位置订阅。"""
    link = None
    auth = AuthenticationProvider(args.auth_helper) if args.auth_helper else None
    try:
        local_address = await controller_address(args.bluetooth_helper)
        stream = await BluetoothStream.open_detected(args.bluetooth_helper, args.device, emit,
                                                    force_live=sys.platform == "win32" and generation > 0)
        link = Link(stream, emit)
        await exchange(args, generation, delivery, link, auth, local_address, emit,
                       lambda: os.getppid() == parent,
                       lambda: os.read(0, 4096) if pending_input() else None)
    finally:
        if link is not None:
            await link.close()
        if auth is not None:
            await auth.close()


async def exchange(args, generation, delivery, link, auth, local_address, emit, alive, read_update):
    """在已检测的字节流上执行握手、认证和位置订阅。调用方负责关闭连接。

    read_update 非阻塞返回一段换行分隔的坐标命令，None 表示暂无更新，空字节表示结束。
    """
    hold_target = generation > 0 or args.command == "connect"
    await link.handshake()
    deadline = math.inf if args.until_stopped else asyncio.get_running_loop().time() + args.duration
    active, last_sent, intervals = set(), {}, {}
    identified = False
    authenticated = False
    recovery_ready = False
    recovery_deadline = asyncio.get_running_loop().time() + 120
    updates = bytearray()
    while (remaining := deadline - asyncio.get_running_loop().time()) > 0:
        if (args.command == "connect" and not (identified and authenticated)
                and asyncio.get_running_loop().time() >= recovery_deadline):
            raise TimeoutError("iAP2 identification or accessory authentication timed out")
        if generation and not recovery_ready and asyncio.get_running_loop().time() >= recovery_deadline:
            raise TimeoutError("Reconnect handshake timed out")
        if args.until_stopped and not alive():
            break
        chunk = read_update() if getattr(args, "stdin_updates", False) else None
        if chunk is not None:
            if not chunk:
                break
            updates.extend(chunk)
            while b"\n" in updates:
                line, _, rest = updates.partition(b"\n")
                updates = bytearray(rest)
                target = json.loads(line)
                if target.get("generation", 0) != generation or (generation and not recovery_ready):
                    continue
                if args.command == "connect" and not (identified and authenticated):
                    continue
                lat, lon = target["latitude"], target["longitude"]
                coordinate(lat, True)
                coordinate(lon, False)
                args.latitude, args.longitude = lat, lon
                if "jitter" in target:
                    args.jitter = target["jitter"] is True
                hold_target = False
                emit(event="target_updated")
            if len(updates) > 4096:
                raise ValueError("Oversized coordinate update")
        try:
            message = await link.receive(min(0.25, remaining))
        except TimeoutError:
            message = None
        if message is not None:
            fields = parameters(message.body)
            emit(
                event="message",
                identifier=f"0x{message.identifier:04x}",
                parameters=[{"id": i, "bytes": len(b)} for i, b in fields],
            )
            if message.identifier == 0x1D00:
                await link.send(identity(args.transport, local_address))
            elif message.identifier == 0x1D02:
                identified = True
                emit(event="identification_accepted")
            elif message.identifier == 0x1D03:
                raise RuntimeError(f"Identification rejected: {[i for i, _ in fields]}")
            elif message.identifier == 0xAA00:
                if auth is None:
                    raise RuntimeError(
                        "Accessory authentication required; no credential configured"
                    )
                await link.send(await auth.certificate())
            elif message.identifier == 0xAA02:
                if auth is None:
                    raise RuntimeError(
                        "Accessory authentication required; no credential configured"
                    )
                challenges = [b for i, b in fields if i == 0]
                if len(challenges) != 1:
                    raise RuntimeError("Invalid authentication challenge parameters")
                await link.send(await auth.sign(challenges[0]))
            elif message.identifier == 0xAA05:
                authenticated = True
                emit(event="authentication_succeeded")
            elif message.identifier == 0xAA04:
                raise RuntimeError("Accessory authentication failed")
            elif message.identifier == 0xFFFA:
                active = {i for i, b in fields if i in (1, 2) and not b}
                intervals = {
                    i - 0x8000: max(1.0, int.from_bytes(b, "big") / 1000)
                    for i, b in fields
                    if i in (0x8001, 0x8002) and len(b) == 4
                }
                last_sent.clear()
                emit(event="location_requested", sentences=sorted(active))
            elif message.identifier == 0xFFFC:
                active.clear()
                emit(event="location_stopped")
        if generation and identified and authenticated and not recovery_ready:
            recovery_ready = True
            emit(event="reconnected", needs_confirmation=hold_target)
        if args.command in ("send", "connect") and identified and authenticated and active and not hold_target:
            now = asyncio.get_running_loop().time()
            due = sorted(
                i
                for i in active
                if now - last_sent.get(i, -math.inf) >= max(args.interval, intervals.get(i, 1))
            )
            if due:
                latitude, longitude = args.latitude, args.longitude
                if args.jitter:
                    latitude, longitude = jittered_point(latitude, longitude)
                sentences = location_sentences(latitude, longitude)
                await link.send(location_message([sentences[i] for i in due]))
                last_sent.update({i: now for i in due})
                delivery.count += 1
                emit(event="location_link_acknowledged", count=delivery.count,
                     latitude=latitude, longitude=longitude, sentences=due)
    emit(
        event="finished",
        identified=identified,
        authenticated=authenticated,
        location_packets_acknowledged=delivery.count,
        phone_location_verified=False,
    )


def main():
    parser = argparse.ArgumentParser(description="Experimental iAP2 accessory-location client")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("probe", "send", "connect"):
        command = commands.add_parser(name)
        command.add_argument("--transport", choices=["bluetooth"], default="bluetooth")
        command.add_argument("--device", help="Previously paired iPhone Bluetooth address")
        command.add_argument("--bluetooth-helper", default="build/bluetooth-bridge")
        command.add_argument(
            "--auth-helper", help="Path to a local JSON-lines certificate/signing provider"
        )
        command.set_defaults(until_stopped=False)
        lifetime = command.add_mutually_exclusive_group()
        lifetime.add_argument("--duration", type=float, default=20 if name == "probe" else 60)
        if name == "connect":
            command.set_defaults(until_stopped=True, stdin_updates=True, interval=1, jitter=False)
        if name == "send":
            lifetime.add_argument("--until-stopped", action="store_true", help="Keep the sending session open until stopped or disconnected")
            command.add_argument("--stdin-updates", action="store_true", help="Read coordinate updates as JSON lines from the host pipe")
            command.add_argument("--latitude", type=float, required=True)
            command.add_argument("--longitude", type=float, required=True)
            command.add_argument("--interval", type=float, default=1)
            command.add_argument("--jitter", action="store_true", help="Sample within 5 metres of the target for each update")

    args = parser.parse_args()
    if args.transport == "bluetooth" and not args.device:
        parser.error("Bluetooth transport requires --device with the paired iPhone address")
    if not math.isfinite(args.duration) or not 0 < args.duration <= 3600:
        parser.error("duration must be between 0 and 3600 seconds")
    if args.command == "send":
        try:
            coordinate(args.latitude, True)
            coordinate(args.longitude, False)
            if not math.isfinite(args.interval) or args.interval < 1:
                raise ValueError("interval must be at least 1 second")
        except ValueError as error:
            parser.error(str(error))
    try:
        asyncio.run(run(args))
    except KeyboardInterrupt:
        emit(event="interrupted")
    except Exception as error:
        emit(event="error", type=type(error).__name__, detail=str(error))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
