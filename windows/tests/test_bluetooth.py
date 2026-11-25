import asyncio
import sys
import unittest
from pathlib import Path
from unittest.mock import AsyncMock

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from peripheral import Peripheral

class ReverseBLE(unittest.IsolatedAsyncioTestCase):
    async def fixture(self,status):
        bridge=Peripheral(Path('.'))
        bridge.peers=AsyncMock(return_value={'phone-A':{'C':20}})
        messages=asyncio.Queue()
        async def send(line):
            verb,device,char,hexdata=line.split()
            self.assertEqual((verb,device,char),('SEND','phone-A','C'))
            raw=bytes.fromhex(hexdata)
            self.assertEqual(raw[4:11],b'\x01123456')
            self.assertEqual(len(raw),19)
            await messages.put('ACK phone-B '+(raw[:4]+b'\0').hex())
            await messages.put('ACK phone-A '+(raw[:4]+bytes([status])).hex())
        bridge.command=send
        bridge.line=messages.get
        return bridge
    async def test_peer_receipt(self):
        bridge=await self.fixture(0)
        await bridge.marker('phone-A','123456',(1,2))
    async def test_denied(self):
        bridge=await self.fixture(1)
        with self.assertRaises(ValueError):await bridge.marker('phone-A','123456',(1,2))
    async def test_disconnected(self):
        bridge=await self.fixture(0)
        with self.assertRaises(ValueError):await bridge.marker('phone-B','123456',(1,2))
