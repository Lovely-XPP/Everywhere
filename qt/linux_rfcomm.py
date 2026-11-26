"""BlueZ 经典蓝牙桥。通过 SDP 解析所选手机的 iAP2 服务通道，双向转发原始字节。"""
import os
import re
import select
import socket
import subprocess
import sys
import xml.etree.ElementTree as ET

ADDRESS = r'(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}'
IAP2 = '00000000-deca-fade-deca-deafdecacafe'


def command(*args, timeout=20):
    result = subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout,
                            env={**os.environ, 'LC_ALL': 'C'}, check=True)
    return result.stdout.decode('utf8', 'replace')


def channel_for(xml):
    # sdptool prints one XML document per record, sometimes preceded by a progress line.
    for record in re.findall(r'<record\b[^>]*>.*?</record>', xml, re.S):
        root = ET.fromstring(record)
        types = root.findall("./attribute[@id='0x0001']//uuid")
        if not any(node.get('value', '').lower() == IAP2 for node in types):
            continue
        for protocol in root.findall("./attribute[@id='0x0004']/sequence/sequence"):
            kind, port = protocol.find('uuid'), protocol.find('uint8')
            if kind is not None and kind.get('value') == '0x0003' and port is not None:
                channel = int(port.attrib['value'], 0)
                if 1 <= channel <= 30:
                    return channel
    return None


def main(args):
    if args == ['--self-test']:
        return 0
    try:
        if args in (['--list'], ['--discover']):
            if args == ['--discover']:
                command('bluetoothctl', '--timeout', '8', 'scan', 'bredr')
            query = ('devices',) if args == ['--discover'] else ('devices', 'Paired')
            for addr, name in re.findall(r'^Device ('+ADDRESS+r') (.+)$', command('bluetoothctl', *query), re.M):
                print(addr.upper()+'\t'+' '.join(name.split()))
            return 0
        controller = re.search(r'^Controller ('+ADDRESS+r')\b', command('bluetoothctl','show'), re.M)
        if not controller:
            return 3
        local = controller[1]
        if args == ['--controller']:
            print(local)
            return 0
        if args[:1] == ['--live']:
            args = args[1:]
        if len(args) != 1 or not re.fullmatch(ADDRESS,args[0]):
            return 8
        print('EW_PHASE discovery', file=sys.stderr, flush=True)
        port = channel_for(command('sdptool', '-i', local, 'browse', '--xml', args[0], timeout=40))
        if port is None:
            return 6
        with socket.socket(socket.AF_BLUETOOTH,socket.SOCK_STREAM,socket.BTPROTO_RFCOMM) as link:
            # Linux uapi BT_SECURITY (level MEDIUM, key_size 0): request an authenticated link.
            link.setsockopt(274, 4, bytes([2,0]))
            link.bind((local,0))
            link.settimeout(40)
            link.connect((args[0],port))
            link.settimeout(None)
            print('EW_OPEN_READY', file=sys.stderr, flush=True)
            while True:
                readable,_,_ = select.select([0,link],[],[])
                if 0 in readable:
                    data = os.read(0,4096)
                    if not data: break
                    link.sendall(data)
                if link in readable:
                    data = link.recv(4096)
                    if not data: break
                    sys.stdout.buffer.write(data)
                    sys.stdout.buffer.flush()
        return 0
    except (OSError, subprocess.SubprocessError, ET.ParseError, ValueError) as exc:
        print(str(exc),file=sys.stderr)
        return 4


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
