"""独立 Mac 辅助程序：通过系统 usbmux 或已配对的 Bonjour 设备运行开发定位。"""
import argparse
import asyncio
from contextlib import AsyncExitStack, aclosing, redirect_stdout
import json
import logging
import os
import sys

from modern_backend import BACKEND_VERSION, Rejected, command_loop, emit, same_device
from pymobiledevice3.exceptions import AlreadyMountedError
from pymobiledevice3.lockdown import create_using_usbmux, get_mobdev2_lockdowns
from pymobiledevice3.remote.tunnel_service import CoreDeviceTunnelProxy
from pymobiledevice3.remote.userspace_tunnel import TunnelProvider, UserspaceRsdTunnel
from pymobiledevice3.services.amfi import AmfiService
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation
from pymobiledevice3.services.mobile_image_mounter import MobileImageMounterService, auto_mount, image_type_for_device
from pymobiledevice3.services.simulate_location import DtSimulateLocation
from pymobiledevice3.usbmux import list_devices


async def paired_wifi(udid):
    """上游的 UDID 参数区分大小写。以设备实报的标识核对，关闭其他候选连接。"""
    async with aclosing(get_mobdev2_lockdowns(only_paired=True, timeout=3)) as candidates:
        async for _, client in candidates:
            if same_device(client.udid, udid):
                return client
            await client.close()
    raise Rejected("未发现所选无线设备。请通过 USB 启用 Wi-Fi，确认手机与电脑 在同一局域网。")


async def connect(udid, transport, pair=False):
    """优先 USB。自动配对仅在用户对指定 USB 设备启动操作时启用。"""
    try:
        devices = await asyncio.wait_for(list_devices(), 5)
    except (OSError, TimeoutError):
        if transport == "USB":
            raise
        devices = []
    for link in ("USB", "Network"):
        if transport not in ("auto", link):
            continue
        row = next((d for d in devices if d.connection_type == link and same_device(d.serial, udid)), None)
        if row:
            client = await create_using_usbmux(serial=row.serial, connection_type=link,
                                               autopair=pair and link == "USB", pair_timeout=45)
            break
    else:
        if transport == "USB":
            raise Rejected("未找到所选 USB 设备，请解锁手机并检查数据线。")
        client = await paired_wifi(udid)
    info = client.short_info
    if not client.paired or not same_device(info.get("UniqueDeviceID"), udid) or info.get("DeviceClass") not in ("iPhone", "iPad"):
        await client.close()
        raise Rejected("未确认所选 iPhone/iPad 的身份，请先通过 USB 连接并信任这台电脑。")
    return client


async def nearby():
    """补充已配对的局域网设备，同时读取系统已枚举设备的名称；探测不会请求配对。"""
    results = {}
    async def name_for(row):
        try:
            client = await asyncio.wait_for(create_using_usbmux(serial=row.serial, connection_type=row.connection_type,
                                                                autopair=False), 3)
            async with client:
                if client.paired and same_device(client.udid, row.serial):
                    results[row.serial] = dict(id=row.serial, name=client.short_info.get("DeviceName") or row.serial,
                                               network=row.connection_type == "Network" or results.get(row.serial, {}).get("network", False))
        except Exception:
            pass  # 尚未信任时，Swift 端继续显示物理设备。
    async def names():
        try:
            rows = await asyncio.wait_for(list_devices(), 4)
        except (OSError, TimeoutError):
            return
        await asyncio.gather(*(name_for(row) for row in rows if row.connection_type in ("USB", "Network")))
    async def network():
        async for _, client in get_mobdev2_lockdowns(only_paired=True, timeout=2):
            async with client:
                if client.paired and client.short_info.get("DeviceClass") in ("iPhone", "iPad"):
                    results[client.udid] = dict(id=client.udid, name=client.short_info.get("DeviceName") or client.udid, network=True)
    # 上游在系统禁止 mDNS 时返回空列表，并通过日志给出权限原因。
    class NetworkWarnings(logging.Handler):
        blocked = False

        def emit(self, record):
            if "bonjour discovery is blocked" in record.getMessage():
                self.blocked = True

    warnings = NetworkWarnings()
    logger = logging.getLogger("pymobiledevice3.bonjour")
    logger.addHandler(warnings)
    try:
        _, failure = await asyncio.gather(names(), network(), return_exceptions=True)
    finally:
        logger.removeHandler(warnings)
    warning = None
    if warnings.blocked:
        warning = "局域网发现受到系统限制。请在 Mac「系统设置 → 隐私与安全性 → 本地网络」允许 Everywhere 后重新打开。"
    elif isinstance(failure, Exception):
        warning = f"无线设备查询失败（{type(failure).__name__}）。"
    return {"devices": list(results.values()), "warning": warning}


async def mount_if_needed(provider):
    """首次使用开发服务时按设备系统选择开发镜像，保留已挂载的镜像。"""
    async with MobileImageMounterService(provider) as mounter:
        if await mounter.is_image_mounted(image_type_for_device(provider)):
            return
    try:
        await auto_mount(provider)
    except AlreadyMountedError:
        pass


async def session(args, consumer=None):
    async with AsyncExitStack() as stack:
        client = await connect(args.udid, args.transport, pair=True)
        await stack.enter_async_context(client)
        if args.prepare_wifi:
            await client.save_pair_record()
            await client.set_enable_wifi_connections(True)
            if not await client.get_enable_wifi_connections():
                raise Rejected("手机未确认 Wi-Fi 连接设置，请保持 USB 连接后重试。")
            return
        version = client.product_version
        system = tuple(map(int, version.split(".")[:2]))
        if system >= (16,) and not await client.get_developer_mode_status():
            try:
                await AmfiService(client).reveal_developer_mode_option_in_ui()
            except Exception:
                pass
            raise Rejected("请在 iPhone「设置 → 隐私与安全性 → 开发者模式」开启并按提示重启，然后重新连接。")
        tunnel = None
        if system < (17,):
            await mount_if_needed(client)
            location = DtSimulateLocation(client)
        else:
            async def provider():
                # 此处复用已核对 UDID 的明确链路，Wi-Fi 不会隐式换到另一台 USB 设备。
                return TunnelProvider(await CoreDeviceTunnelProxy.create(client))
            if system < (17, 4):
                tunnel = UserspaceRsdTunnel(serial=client.udid, autopair=False, remotepairing=True)
                try:
                    rsd = await stack.enter_async_context(tunnel)
                except Exception as exc:
                    raise Rejected("iOS 17.0–17.3 需要可用的 RemotePairing 配对记录。可更新至 17.4 或以上后通过 USB 准备。") from exc
            else:
                tunnel = UserspaceRsdTunnel(serial=args.udid, provider_factory=provider)
                rsd = await stack.enter_async_context(tunnel)
            if not same_device(rsd.udid, args.udid):
                raise Rejected("开发服务报告的设备与所选设备不一致。")
            await mount_if_needed(rsd)
            dvt = await stack.enter_async_context(DvtProvider(rsd))
            location = await stack.enter_async_context(LocationSimulation(dvt))
        if consumer is not None:
            return await consumer(tunnel, location)
        emit(args.udid, "ready", productVersion=version, backendVersion=BACKEND_VERSION)
        return await command_loop(args.udid, tunnel, location, asyncio.Event())


def main():
    os.umask(0o077)  # 新配对的本机记录只允许当前账户读取。
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid")
    parser.add_argument("--transport", choices=["USB", "Network", "auto"], default="auto")
    parser.add_argument("--prepare-wifi", action="store_true")
    parser.add_argument("--nearby", action="store_true")
    parser.add_argument("--check-runtime", action="store_true")
    args = parser.parse_args()
    try:
        if args.check_runtime:
            from importlib.metadata import version
            if version("pymobiledevice3") != BACKEND_VERSION:
                raise Rejected("打包依赖版本不匹配")
            print(BACKEND_VERSION)
        elif args.nearby:
            with redirect_stdout(sys.stderr):
                rows = asyncio.run(nearby())
            print(json.dumps(rows))
        elif args.udid:
            if args.prepare_wifi:
                args.transport = "USB"
            with redirect_stdout(sys.stderr):
                return asyncio.run(session(args))
        else:
            parser.error("缺少目标设备")
    except Exception as exc:
        message = str(exc) if isinstance(exc, Rejected) else f"{type(exc).__name__} · {str(exc)[:180]}"
        emit(args.udid, "error", status="rejected", message=message)
        return 1


if __name__ == "__main__":
    sys.exit(main())
