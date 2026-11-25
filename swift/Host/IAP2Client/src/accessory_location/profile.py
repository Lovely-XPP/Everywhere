"""Minimal accessory identity and GPS sentence generation."""

import math
import random
import struct
from datetime import UTC, datetime

from .wire import Message, parameter, text_parameter


def identity(transport="usb", bluetooth_address: bytes | None = None) -> Message:
    fields = [
        text_parameter(i, v)
        for i, v in enumerate(
            ("Accessory Location Lab", "AL-1", "Local Research", "AL-LOCAL-001", "0.1", "1")
        )
    ]
    fields += [
        parameter(6, struct.pack(">H", 0xFFFB)),
        parameter(7, struct.pack(">HH", 0xFFFA, 0xFFFC)),
        parameter(8, b"\0"),
        parameter(9, b"\0\0"),
        text_parameter(12, "en"),
        text_parameter(13, "en"),
    ]
    component = parameter(0, b"\0\0") + text_parameter(1, "Location Transport") + parameter(2)
    if transport == "usb":
        fields.append(parameter(16, component))
    elif transport == "bluetooth":
        if bluetooth_address is None or len(bluetooth_address) != 6:
            raise ValueError("Bluetooth identity needs a six-byte local controller address")
        fields.append(parameter(17, component + parameter(3, bluetooth_address)))
    else:
        raise ValueError("Unknown transport")
    location = parameter(0, b"\0\0") + text_parameter(1, "GPS")
    fields.append(parameter(22, location + parameter(17) + parameter(18)))
    return Message(0x1D01, b"".join(fields))


def coordinate(value: float, latitude: bool) -> tuple[str, str]:
    limit = 90 if latitude else 180
    if not math.isfinite(value) or not -limit <= value <= limit:
        raise ValueError(f"Coordinate out of range: {value}")
    # Round once to millionths of a minute, carrying across degree boundaries.
    scale = 1_000_000
    degrees, remainder = divmod(round(abs(value) * 60 * scale), 60 * scale)
    minutes, fraction = divmod(remainder, scale)
    hemisphere = ("S" if value < 0 else "N") if latitude else ("W" if value < 0 else "E")
    return f"{degrees:0{2 if latitude else 3}d}{minutes:02d}.{fraction:06d}", hemisphere


def jittered_point(latitude: float, longitude: float) -> tuple[float, float]:
    """在目标周围半径约 5 米的圆内均匀抽取一次，输入和返回值均为十进制度。"""
    distance = 5 * math.sqrt(random.random())
    bearing = math.tau * random.random()
    arc = distance / 6_371_008.8
    phi = math.radians(latitude)
    # 在目标的局部北、东切平面选方向，再沿球面移动；极点也无需除以 cos(phi)。
    north = math.sin(arc) * math.cos(bearing)
    east = math.sin(arc) * math.sin(bearing)
    horizontal = math.cos(phi) * math.cos(arc) - math.sin(phi) * north
    vertical = math.sin(phi) * math.cos(arc) + math.cos(phi) * north
    lat = math.degrees(math.atan2(vertical, math.hypot(horizontal, east)))
    lon = longitude + math.degrees(math.atan2(east, horizontal))
    return lat, (lon + 180) % 360 - 180


def sentence(body: str) -> str:
    checksum = 0
    for byte in body.encode("ascii"):
        checksum ^= byte
    return f"${body}*{checksum:02X}\r\n"


def location_sentences(latitude: float, longitude: float, when: datetime | None = None):
    when = (when or datetime.now(UTC)).astimezone(UTC)
    lat, north = coordinate(latitude, True)
    lon, east = coordinate(longitude, False)
    clock = when.strftime("%H%M%S") + ".00"
    date = when.strftime("%d%m%y")
    return {
        1: sentence(f"GPGGA,{clock},{lat},{north},{lon},{east},1,08,0.9,10.0,M,0.0,M,,"),
        2: sentence(f"GPRMC,{clock},A,{lat},{north},{lon},{east},0.0,0.0,{date},,,A"),
    }


def location_message(sentences: list[str]) -> Message:
    return Message(0xFFFB, b"".join(text_parameter(0, s) for s in sentences))
