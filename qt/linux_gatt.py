"""BlueZ GATT 服务。使用每台手机独立的 AcquireNotify 管道，按设备关联回执。"""
import asyncio
import socket
import sys

from dbus_next import BusType, DBusError, Message, MessageType, Variant
from dbus_next.aio import MessageBus
from dbus_next.constants import PropertyAccess
from dbus_next.service import ServiceInterface, dbus_property, method

BASE = '/org/everywhere/gatt'
SERVICE = BASE + '/service0'
ADS = '/org/everywhere/advertisement'
REVERSE = '62d42c56-03cb-4895-adb6-08b640f25f71'
BEACON = '8cc42c82-ac28-4f92-a5cf-4e76267234f4'
FIELDS = {'C':'971735a6-f422-4bb2-a924-47fb7a5385c3', 'R':'221c5cf2-5e82-4bb1-ab2d-48a729b9071f',
          'A':'2244d789-b54f-4736-afa4-e98e7c54118c', 'S':'18a6b6aa-4113-477e-8c1c-4bb5c977aa26'}
RO = PropertyAccess.READ


class Service(ServiceInterface):
    def __init__(self, uuid):
        super().__init__('org.bluez.GattService1')
        self.uuid = uuid

    @dbus_property(access=RO)
    def UUID(self) -> 's':
        return self.uuid

    @dbus_property(access=RO)
    def Primary(self) -> 'b':
        return True


class Advertisement(ServiceInterface):
    def __init__(self, uuid):
        super().__init__('org.bluez.LEAdvertisement1')
        self.uuid = uuid

    @dbus_property(access=RO)
    def Type(self) -> 's':
        return 'peripheral'

    @dbus_property(access=RO)
    def ServiceUUIDs(self) -> 'as':
        return [self.uuid]

    @method()
    def Release(self):
        pass


class Field(ServiceInterface):
    def __init__(self, kind, flags):
        super().__init__('org.bluez.GattCharacteristic1')
        self.kind, self.flags = kind, flags

    @dbus_property(access=RO)
    def UUID(self) -> 's':
        return FIELDS[self.kind]

    @dbus_property(access=RO)
    def Service(self) -> 'o':
        return SERVICE

    @dbus_property(access=RO)
    def Flags(self) -> 'as':
        return self.flags


class Receipt(Field):
    @method()
    def WriteValue(self, data: 'ay', options: 'a{sv}'):
        if len(data) != 5 or 'device' not in options or options.get('offset', Variant('q',0)).value:
            raise DBusError('org.bluez.Error.InvalidValueLength','Invalid marker receipt')
        print('ACK', options['device'].value.encode().hex(), bytes(data).hex(), flush=True)


class Indications(Field):
    def __init__(self, kind, bus):
        super().__init__(kind, ['indicate','notify','encrypt-read'])
        self.peers = {}
        self.bus = bus

    @dbus_property(access=RO)
    def NotifyAcquired(self) -> 'b':
        return bool(self.peers)

    @method()
    def AcquireNotify(self, options: 'a{sv}') -> 'hq':
        if 'device' not in options or 'mtu' not in options:
            raise DBusError('org.bluez.Error.NotSupported','BlueZ must identify the subscribing device')
        key = options['device'].value.encode().hex()
        mtu = options['mtu'].value
        self.remove(key)
        local, remote = socket.socketpair(socket.AF_UNIX,socket.SOCK_SEQPACKET)
        local.setblocking(False)
        self.peers[key] = (local,mtu-3)
        loop = asyncio.get_running_loop()
        def readable():
            try:
                if local.recv(1): return  # an indication confirmation
            except BlockingIOError:
                return
            except OSError:
                pass
            self.remove(key)
        loop.add_reader(local, readable)
        # dbus-next queues the fd for sendmsg. Release our copy after an ordered bus round trip.
        async def relinquish():
            try:
                await self.bus.call(Message(destination='org.freedesktop.DBus', path='/org/freedesktop/DBus',
                                            interface='org.freedesktop.DBus', member='GetId'))
            finally:
                remote.close()
        loop.create_task(relinquish())
        return [remote.fileno(),mtu]

    def remove(self,key):
        item = self.peers.pop(key,None)
        if item:
            asyncio.get_running_loop().remove_reader(item[0])
            item[0].close()


class Status(Field):
    def __init__(self):
        super().__init__('S',['read','encrypt-read','notify'])
        self.snapshot = b'{"target":"","authenticated":false,"message":"Ready"}'
        self.notifying = False
        self.reads = {}

    @dbus_property(access=RO)
    def Value(self) -> 'ay':
        return b'\x00'

    @method()
    def ReadValue(self, options:'a{sv}') -> 'ay':
        device = options['device'].value
        offset = options.get('offset', Variant('q',0)).value
        if not offset:
            self.reads[device] = self.snapshot
        data = self.reads.get(device,b'')
        if offset > len(data):
            raise DBusError('org.bluez.Error.InvalidOffset','Invalid offset')
        return data[offset:]

    @method()
    def StartNotify(self):
        self.notifying = True

    @method()
    def StopNotify(self):
        self.notifying = False


async def main(args):
    if args == ['--self-test']:
        assert Receipt('A',['write']).UUID == FIELDS['A']
        return
    if args not in (['markers'],['status']):
        raise ValueError('Expected markers or status')
    status = args == ['status']
    bus = await MessageBus(bus_type=BusType.SYSTEM,negotiate_unix_fd=True).connect()
    async def call(path, interface, member, signature='', body=None):
        reply = await bus.call(Message(destination='org.bluez',path=path,interface=interface, member=member,
                                       signature=signature,body=body or []))
        if reply.message_type == MessageType.ERROR:
            raise RuntimeError(f'{member}: {reply.error_name} {reply.body}')
        return reply.body
    try:
        owner = await bus.call(Message(destination='org.freedesktop.DBus',path='/org/freedesktop/DBus',
                                       interface='org.freedesktop.DBus',member='GetNameOwner',
                                       signature='s',body=['org.bluez']))
        if owner.message_type == MessageType.ERROR:
            raise RuntimeError('需要已运行的 BlueZ 服务')
        def bluez_only(message):
            if (message.message_type == MessageType.METHOD_CALL
                    and message.path and message.path.startswith('/org/everywhere/')
                    and message.sender != owner.body[0]):
                return Message.new_error(message,'org.freedesktop.DBus.Error.AccessDenied','BlueZ only')
        bus.add_message_handler(bluez_only)
        objects, = await call('/','org.freedesktop.DBus.ObjectManager','GetManagedObjects')
        adapter = next((p for p,v in objects.items() if 'org.bluez.GattManager1' in v
                       and 'org.bluez.LEAdvertisingManager1' in v and v['org.bluez.Adapter1']['Powered'].value),None)
        if not adapter:
            raise RuntimeError('需要已开启且支持 BLE 外设广播的 BlueZ 适配器')
        uuid = BEACON if status else REVERSE
        bus.export(SERVICE, Service(uuid))
        fields = {'S':Status()} if status else {k:Indications(k,bus) for k in ('C','R')}
        if not status:
            fields['A'] = Receipt('A',['write','encrypt-write'])
        for index, field in enumerate(fields.values()):
            bus.export(f'{SERVICE}/char{index}',field)
        bus.export(ADS,Advertisement(uuid))
        await call(adapter,'org.bluez.GattManager1','RegisterApplication','oa{sv}',[BASE,{}])
        await call(adapter,'org.bluez.LEAdvertisingManager1','RegisterAdvertisement','oa{sv}',[ADS,{}])
        print('READY',flush=True)
        while line := await asyncio.to_thread(sys.stdin.readline):
            words=line.split()
            if words == ['PEERS'] and not status:
                for k in ('C','R'):
                    for device,(_,cap) in list(fields[k].peers.items()):
                        print('PEER',device,k,cap)
                print('END',flush=True)
            elif words[:1] == ['SEND'] and len(words)==4 and not status:
                _,device,k,data = words
                try:
                    conn,cap = fields[k].peers[device]
                    payload = bytes.fromhex(data)
                    if len(payload)>cap: raise ValueError('MTU too small')
                    conn.send(payload)
                except (OSError,KeyError,ValueError):
                    print('ERROR peer unreachable',flush=True)
            elif words[:1] == ['STATUS'] and len(words)==2 and status:
                field=fields['S']
                field.snapshot=bytes.fromhex(words[1])
                if field.notifying: field.emit_properties_changed({'Value':b'\x00'})
    finally:
        bus.disconnect()


if __name__ == '__main__':
    asyncio.run(main(sys.argv[1:]))
