"""WGS 84 coordinates, BLE payloads and device identity shared by the Windows controller."""
import datetime as dt
import functools
import math
import operator
import re
import struct

SERVICE = "b26ff64e-e453-4987-9102-a99ab34b6db8"
COMMAND = "971735a6-f422-4bb2-a924-47fb7a5385c3"
RMC = "221c5cf2-5e82-4bb1-ab2d-48a729b9071f"


def point(lat, lon):
    if isinstance(lat, bool) or isinstance(lon, bool):
        raise ValueError("经纬度必须是数字")
    lat, lon = float(lat), float(lon)
    if not (-90 <= lat <= 90 and -180 <= lon <= 180):
        raise ValueError("纬度范围为 ±90°，经度范围为 ±180°")
    return lat, lon


def device_key(value):
    return value.replace("-", "").casefold()


def merge_devices(rows, details):
    result = {}
    def add(serial, name=None, usb=False, wifi=False):
        item = result.setdefault(device_key(serial), dict(id=serial, name=serial, usb=False, wifi=False))
        if name and name != serial:
            item['name'] = name
        item['usb'] |= usb
        item['wifi'] |= wifi
    for row in rows:
        if row.connection_type in ('USB', 'Network'):
            add(row.serial, usb=row.connection_type == 'USB', wifi=row.connection_type == 'Network')
    for row in details:
        add(row['id'], row.get('name'), wifi=bool(row.get('network')))
    return sorted(result.values(), key=lambda item: (not item['usb'], item['name'], item['id']))


def ble_packet(code, coords, rmc=False, capacity=20, now=None):
    if not re.fullmatch('[0-9]{6}', code):
        raise ValueError("请输入手机显示的六位接收码")
    code = code.encode('ascii')
    if coords is None:
        return b'\x00' + code
    lat, lon = point(*coords)
    def integer(value):
        return int(math.copysign(math.floor(abs(value) + .5), value))
    compact = b'\x01' + code + struct.pack('>ii', integer(lat*1e6), integer(lon*1e6))
    if not rmc:
        return compact
    def dm(value, width):
        degrees, minutes = divmod(integer(abs(value)*6e6), 6000000)
        return f"{degrees:0{width}d}{minutes // 100000:02d}.{minutes % 100000:05d}"
    now = now or dt.datetime.now(dt.timezone.utc)
    fields = ('GPRMC', now.strftime('%H%M%S'), 'A', dm(lat, 2), 'S' if lat < 0 else 'N',
              dm(lon, 3), 'W' if lon < 0 else 'E', '', '', now.strftime('%d%m%y'), '', '', 'S')
    body = ','.join(fields).encode()
    sentence = b'\x02' + code + b'$' + body + f"*{functools.reduce(operator.xor, body):02X}\r\n".encode()
    return sentence if len(sentence) <= capacity else compact
