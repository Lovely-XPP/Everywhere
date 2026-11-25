#!/usr/bin/env python3
"""P0 真机定位开发模拟辅助进程：一进程、一台已配对 USB 设备、一个 DVT 会话。

只处理标准输入的 JSONL 指令，标准输出是结构化回执。保留 DVT 会话直到清除或退出。
不会发起配对、自动提权、切换其他设备或在断线后重放旧指令。
"""

import argparse
import asyncio
from contextlib import AsyncExitStack, redirect_stdout
from importlib.metadata import PackageNotFoundError, version
import json
import math
import os
import re
import signal
import sys


BACKEND_VERSION = "11.62.0"
CONNECT_TIMEOUT = 45  # 秒；启动各阶段分别计时。
COMMAND_TIMEOUT = 15  # 秒；每条 DVT 指令的本地等待上限。
PROTOCOL_OUT = sys.stdout


class Rejected(Exception):
    """未执行修改设备的指令即可确认拒绝请求。"""


def emit(device_id, event, **fields):
    """输出单行 JSON；device_id 为启动时明确指定的目标 UDID。"""
    payload = {"event": event, "deviceID": device_id, **fields}
    print(json.dumps(payload, ensure_ascii=False, allow_nan=False),
          file=PROTOCOL_OUT, flush=True)


def validate_request(raw):
    """校验请求标识、命令及 WGS 84 坐标，返回规范化命令。

    :param raw: 一条解码后的 JSON 对象。
    :returns: (requestID, command, coordinates)，坐标为十进制度或 None。
    :raises Rejected: 非法字段、超出范围或不支持的命令。
    """
    if not isinstance(raw, dict):
        raise Rejected("请求必须是 JSON 对象")
    request_id = raw.get("requestID")
    if not isinstance(request_id, str) or not request_id.strip() or len(request_id) > 128:
        raise Rejected("requestID 必须是非空字符串（最长 128 字符）")
    command = raw.get("command")
    if command not in ("set", "clear", "quit"):
        raise Rejected("command 只允许 set、clear、quit")
    if command != "set":
        return request_id, command, None
    coordinates = []
    for name, bound in (("latitude", 90), ("longitude", 180)):
        value = raw.get(name)
        if type(value) not in (int, float) or not -bound <= value <= bound or not math.isfinite(value):
            raise Rejected(f"{name} 必须为 [-{bound}, {bound}] 内的有限数值")
        coordinates.append(float(value))
    return request_id, command, tuple(coordinates)


async def preflight(list_devices, create_using_usbmux, device_id):
    """核实当前 USB 真机已配对、设备类别和系统范围；不触发配对。

    :returns: (usbmuxd 报告的实际序列号, ProductVersion 字符串)。
    :raises Rejected: UDID 不匹配、未配对、非手机/平板或系统低于 17.4。
    连接异常及超时向调用方传播；此阶段不会改动模拟位置。
    """
    connected = await asyncio.wait_for(list_devices(), CONNECT_TIMEOUT)
    matches = [device.serial for device in connected
               if device.connection_type == "USB" and same_device(device.serial, device_id)]
    if len(matches) != 1:
        raise Rejected("USB 列表中没有唯一匹配指定 UDID 的设备")
    serial = matches[0]
    client = await asyncio.wait_for(create_using_usbmux(
        serial=serial, autopair=False, connection_type="USB"), CONNECT_TIMEOUT)
    async with client:
        if not client.paired:
            raise Rejected("请先在真机与 Mac 上完成信任配对")
        info = client.short_info
        if not same_device(info.get("UniqueDeviceID"), device_id):
            raise Rejected("配对设备 UDID 与目标不一致")
        if info.get("ConnectionType") != "USB":
            raise Rejected("此原型只允许 USB 连接")
        if info.get("DeviceClass") not in ("iPhone", "iPad"):
            raise Rejected("此原型仅面向 iPhone 和 iPad")
        product_version = client.product_version
        match = re.match(r"^(\d+)\.(\d+)(?:\.|$)", product_version)
        if not match or tuple(map(int, match.groups())) < (17, 4):
            raise Rejected("此后端候选范围为 iOS/iPadOS 17.4 及更新版本")
        return serial, product_version


def same_device(reported, expected):
    """比较设备报告与指定的 UDID，统一大小写和 usbmuxd 可能省略的分隔符。"""
    return (isinstance(reported, str)
            and reported.replace("-", "").casefold() == expected.replace("-", "").casefold())


class CommandSession:
    """串行处理单设备命令，记录本进程可能尚未清除的模拟和请求结果。"""

    def __init__(self, device_id, location):
        self.device_id = device_id
        self.location = location
        self.may_need_clear = False
        self.receipts = {}

    def receipt(self, request_id, command, status, message):
        """构造不含位置坐标的回执；sent 只表示调用返回，无独立真机观测。"""
        return dict(requestID=request_id, command=command, status=status, message=message)

    async def clear_owned(self):
        """仅清除本进程可能设过的位置；超时或异常时保留未清除状态。"""
        if self.may_need_clear:
            await asyncio.wait_for(self.location.clear(), COMMAND_TIMEOUT)
            self.may_need_clear = False

    async def process(self, line):
        """解析并串行执行单行命令；无需重发已有 requestID，返回是否应结束会话。

        本地解析错误不会触及设备。设备调用超时、异常后退出，避免继续执行排队命令。
        """
        raw = None
        try:
            raw = json.loads(line)
            request_id, command, point = validate_request(raw)
            if "deviceID" in raw and not same_device(raw["deviceID"], self.device_id):
                raise Rejected("请求中的 deviceID 与启动目标不一致")
        except (Rejected, ValueError, UnicodeError) as exc:
            if isinstance(raw, dict) and isinstance(raw.get("requestID"), str):
                safe_command = raw.get("command")
                if safe_command not in ("set", "clear", "quit"):
                    safe_command = None
                emit(self.device_id, "receipt", **self.receipt(
                    raw.get("requestID"), safe_command, "rejected", str(exc)))
            else:
                emit(self.device_id, "error", status="rejected", message="无效 JSONL 请求")
            return False, True

        fingerprint = (command, point)
        cached = self.receipts.get(request_id)
        if cached is not None:
            prior_fingerprint, prior_receipt = cached
            result = (prior_receipt if prior_fingerprint == fingerprint else self.receipt(
                request_id, command, "rejected", "requestID 已用于其他指令"))
            emit(self.device_id, "receipt", **result)
            return False, True

        try:
            if command == "set":
                # 发送前即标记可能有副作用，未知结果时仍需要恢复。
                self.may_need_clear = True
                await asyncio.wait_for(self.location.set(*point), COMMAND_TIMEOUT)
                message = "设点调用已返回；等待独立 Probe 确认"
            elif command == "clear":
                # 显式 clear 可用于用户主动恢复上次失联留下的模拟。
                await asyncio.wait_for(self.location.clear(), COMMAND_TIMEOUT)
                self.may_need_clear = False
                message = "清除调用已返回；真实位置是否恢复尚未知"
            else:
                was_owned = self.may_need_clear
                await self.clear_owned()
                message = ("退出前清除调用已返回；恢复尚未知" if was_owned
                           else "退出；本进程没有待清除的位置")
            result = self.receipt(request_id, command, "sent", message)
            self.receipts[request_id] = (fingerprint, result)
            emit(self.device_id, "receipt", **result)
            return command == "quit", True
        except Exception as exc:
            result = self.receipt(request_id, command, "unknown",
                                  f"调用未确认（{type(exc).__name__}）；请核对真机并清除")
            self.receipts[request_id] = (fingerprint, result)
            emit(self.device_id, "receipt", **result)
            return True, False


async def command_loop(device_id, tunnel, location, stop):
    """在异步事件循环中读取标准输入；定期核查隧道关闭，EOF 时尝试恢复。

    仅在本进程曾提交 set 的情况下进行自动清除。不会重连或自动重试 set。
    :returns: 0 表示正常结束；2 表示设备结果未知或清除失败。
    """
    session = CommandSession(device_id, location)
    reader = asyncio.StreamReader()
    loop = asyncio.get_running_loop()
    transport, _ = await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer)
    pending = None
    success = True
    try:
        pending = asyncio.create_task(reader.readline())
        while not stop.is_set():
            if tunnel is not None and tunnel.rsd is None:
                emit(device_id, "error", status="unknown", message="设备连接已断开；请重连后显式清除")
                success = False
                break
            done, _ = await asyncio.wait({pending}, timeout=1)
            if stop.is_set():
                break
            if not done:
                continue
            line = pending.result()
            pending = None
            if not line:  # 宿主关闭 stdin 或终端 EOF。
                break
            if not line.strip():
                pending = asyncio.create_task(reader.readline())
                continue
            should_exit, success = await session.process(line)
            if should_exit:
                break
            pending = asyncio.create_task(reader.readline())
    except Exception as exc:
        emit(device_id, "error", status="unknown", message=f"辅助进程通信中断（{type(exc).__name__}）")
        success = False
    finally:
        if pending is not None:
            pending.cancel()
            await asyncio.gather(pending, return_exceptions=True)
        transport.close()
        if session.may_need_clear:
            try:
                if tunnel is not None and tunnel.rsd is None:
                    raise ConnectionError()
                await session.clear_owned()
                emit(device_id, "cleanup", status="sent", message="退出前清除调用已返回；恢复尚未知")
            except Exception as exc:
                success = False
                emit(device_id, "cleanup", status="unknown",
                     message=f"无法确认退出前清除（{type(exc).__name__}）；请重连后显式清除")
    return 0 if success else 2


async def prepare_channel(device_id, stack, stop, list_devices, create_client, make_tunnel, make_dvt, make_location):
    """仅在 ready 前重试一次瞬时连接错误。每次重新核验 USB 身份，释放失败尝试的通道。"""
    for attempt in range(2):
        if stop.is_set():
            return None
        try:
            async with AsyncExitStack() as trial:
                serial, product_version = await preflight(list_devices, create_client, device_id)
                tunnel = make_tunnel(serial=serial, autopair=False, remotepairing_fallback=False)
                rsd = await asyncio.wait_for(trial.enter_async_context(tunnel), CONNECT_TIMEOUT)
                if not same_device(rsd.udid, device_id):
                    raise Rejected("DVT 隧道的 UDID 与目标不一致")
                dvt = await asyncio.wait_for(trial.enter_async_context(make_dvt(rsd)), CONNECT_TIMEOUT)
                location = await asyncio.wait_for(trial.enter_async_context(make_location(dvt)), CONNECT_TIMEOUT)
                stack.push_async_callback(trial.pop_all().aclose)
                return tunnel, location, product_version
        except (ConnectionError, asyncio.TimeoutError):
            if attempt:
                raise
            if stop.is_set():
                return None


async def serve(device_id):
    """准备用户已信任的 USB 设备，在同一 DVT 通道执行所有指令。

    依赖不匹配、权限/开发者模式或建立通道失败时拒绝运行，不申请额外权限。
    """
    try:
        actual_version = version("pymobiledevice3")
    except PackageNotFoundError as exc:
        raise Rejected(f"请先安装 pymobiledevice3 {BACKEND_VERSION}") from exc
    if actual_version != BACKEND_VERSION:
        raise Rejected(f"需要 pymobiledevice3 {BACKEND_VERSION}，已安装 {actual_version}")
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.usbmux import list_devices
    from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)
    try:
        async with AsyncExitStack() as stack:
            # 总预算短于主机的 90 秒握手超时。ready 后 command_loop 不在重试范围内。
            channel = await asyncio.wait_for(prepare_channel(
                device_id, stack, stop, list_devices, create_using_usbmux,
                UserspaceRsdTunnel, DvtProvider, LocationSimulation), timeout=75)
            if channel is None or stop.is_set():
                return 0
            tunnel, location, product_version = channel
            emit(device_id, "ready", productVersion=product_version, backendVersion=BACKEND_VERSION)
            return await command_loop(device_id, tunnel, location, stop)
    finally:
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.remove_signal_handler(sig)


def main():
    """命令入口。返回 0 正常结束、1 启动失败、2 设备结果未知。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", required=True, help="用户选定且已配对的 USB 真机 UDID")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-fA-F-]{8,64}", args.udid):
        emit(args.udid, "error", status="rejected", message="UDID 格式无效")
        return 1
    if sys.platform != "darwin":
        emit(args.udid, "error", status="rejected", message="此 P0 后端限定 macOS")
        return 1
    # 用户态隧道库会读取此环境变量；不允许将本地 USB 会话重定向到远程 usbmuxd。
    if any(os.getenv(name) not in (None, "", "/var/run/usbmuxd", "/private/var/run/usbmuxd")
           for name in ("USBMUXD_SOCKET_ADDRESS", "PYMOBILEDEVICE3_USBMUX")):
        emit(args.udid, "error", status="rejected", message="仅支持本机默认 usbmuxd；请移除自定义连接地址")
        return 1
    # 上游工具的普通文本与诊断流进入 stderr，不污染 stdout JSONL。
    with redirect_stdout(sys.stderr):
        try:
            return asyncio.run(serve(args.udid))
        except Rejected as exc:
            emit(args.udid, "error", status="rejected", message=str(exc))
            return 1
        except Exception as exc:
            emit(args.udid, "error", status="unknown",
                 message=f"后端启动或退出失败（{type(exc).__name__}）；请检查依赖、USB、配对及开发者模式")
            return 2


if __name__ == "__main__":
    sys.exit(main())
