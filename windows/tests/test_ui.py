"""Drive the real controller widgets with an in-memory device service."""
import asyncio
import os
from pathlib import Path
import sys
import time
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock

os.environ.setdefault('QT_QPA_PLATFORM','offscreen')
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
try:
    from PySide6 import QtCore as C, QtWidgets as W
except ImportError as exc:
    raise unittest.SkipTest('Qt bindings are required for UI smoke tests') from exc
from app import Desk

class DesktopWorkflow(unittest.TestCase):
    def test_select_apply_change_restore(self):
        app=W.QApplication.instance() or W.QApplication([])
        app.setOrganizationName('Everywhere-test')
        app.setApplicationName('ui-test')
        desk=Desk()
        desk.map.fetch=lambda _:None
        desk.confirm_send=lambda:False
        output=SimpleNamespace(set=AsyncMock(),clear=AsyncMock())
        class Fixture:
            async def list_devices(self):
                return [SimpleNamespace(serial=s,connection_type='USB') for s in ('TEST-A','TEST-B')]
            async def nearby(self):
                return dict(devices=[dict(id='TEST-A',name='Phone',network=True),
                                     dict(id='TEST-B',name='Phone',network=False)])
            async def session(self,args,consumer):
                if args.udid!='TEST-B': raise AssertionError('wrong target')
                await consumer(None,output)
        desk.soft.backend=Fixture()
        def wait(condition):
            deadline=time.monotonic()+4
            while not condition() and time.monotonic()<deadline:
                app.processEvents()
                time.sleep(.005)
            self.assertTrue(condition())
        try:
            desk.show()
            desk.enter('software')
            wait(lambda:not desk.scanning)
            self.assertEqual(desk.devices.count(),2)
            self.assertEqual(desk.devices.currentIndex(),-1)
            self.assertFalse(desk.apply.isEnabled())
            desk.devices.setCurrentIndex(desk.devices.findData('TEST-B'))
            desk.map.picked.emit(22.5,114.5)
            desk.apply.click()
            output.set.assert_not_awaited()
            desk.confirm_send=lambda:True
            desk.apply.click()
            wait(lambda:not desk.busy)
            output.set.assert_awaited_once_with(22.5,114.5)
            desk.lat.setText('23.25')
            desk.apply.click()
            wait(lambda:not desk.busy)
            self.assertEqual(output.set.await_args.args,(23.25,114.5))
            desk.clear.click()
            wait(lambda:not desk.busy)
            output.clear.assert_awaited_once()
            desk.back.click()
            wait(lambda:desk.stack.currentIndex()==0)
        finally:
            desk.closed=True
            desk.close()
            desk.jobs.loop.call_soon_threadsafe(desk.jobs.loop.stop)
            desk.jobs.thread.join(timeout=2)
            desk.jobs.loop.close()
