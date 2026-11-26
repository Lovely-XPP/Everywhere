"""Drive the real controller widgets with an in-memory device service."""
import asyncio
import os
from pathlib import Path
import sys
import time
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock

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
            desk.software_devices.setCurrentRow(desk.devices.findData('TEST-B'))
            self.assertEqual(desk.devices.currentData(),'TEST-B')
            desk.map.picked.emit(22.5,114.5)
            desk.apply.click()
            output.set.assert_not_awaited()
            def changed_while_confirming():
                desk.devices.setCurrentIndex(desk.devices.findData('TEST-A'))
                return True
            desk.confirm_send=changed_while_confirming
            desk.apply.click()
            output.set.assert_not_awaited()
            self.assertNotEqual(desk.devices.itemText(0),desk.devices.itemText(1))
            desk.devices.setCurrentIndex(desk.devices.findData('TEST-B'))
            desk.confirm_send=lambda:True
            desk.apply.click()
            wait(lambda:not desk.busy)
            output.set.assert_awaited_once_with(22.5,114.5)
            desk.lat.setText('23.25')
            desk.apply.click()
            wait(lambda:not desk.busy)
            self.assertEqual(output.set.await_args.args,(23.25,114.5))
            desk.confirm_restore=lambda:False
            desk.clear.click()
            output.clear.assert_not_awaited()
            desk.confirm_restore=lambda:True
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

    def test_pairing_panel_and_place_book(self):
        from place_browser import PlaceBrowser
        app=W.QApplication.instance() or W.QApplication([])
        app.setOrganizationName('Everywhere-test')
        app.setApplicationName('ui-panel-test')
        C.QSettings().setValue('map/gcj',True)
        desk=Desk()
        desk.map.fetch=lambda _:None
        desk.bt.scan=AsyncMock(side_effect=[[],[dict(id='AA:BB',name='Test iPhone')]])
        desk.bt.connect_accessory=AsyncMock()
        desk.beacon.start=AsyncMock()
        def settle():
            deadline=time.monotonic()+3
            while (desk.busy or desk.scanning) and time.monotonic()<deadline:
                app.processEvents()
                time.sleep(.005)
            app.processEvents()
            self.assertFalse(desk.busy or desk.scanning)
        try:
            desk.resize(800,560); desk.show(); desk.enter('classic'); settle()
            self.assertGreaterEqual(desk.pair.height(),desk.pair.layout().minimumSize().height())
            desk.pair.click(); settle()
            self.assertTrue(desk.pairing_box.isVisible())
            self.assertEqual(desk.nearby.count(),1)
            desk.nearby.itemClicked.emit(desk.nearby.item(0)); settle()
            desk.bt.connect_accessory.assert_awaited_once_with('AA:BB','')
            self.assertFalse(desk.pairing_box.isVisible())
            self.assertFalse(desk.apply.isEnabled())
            desk.remember('favorites','上海',(31.2304,121.4737))
            desk.places('favorites')
            book=desk.findChild(PlaceBrowser)
            app.processEvents()
            self.assertTrue(book.isVisible())
            desk.send=Mock()
            book.items.itemClicked.emit(book.items.item(0))
            self.assertEqual(desk.coords(),(31.2304,121.4737))
            self.assertEqual(desk.place_title.text(),'上海')
            desk.send.assert_not_called()
            self.assertTrue(desk.place_datum.currentData())
            from geo import project
            origin=desk.map.origin()
            for value in (False,True):
                desk.start_datum.setCurrentIndex(desk.start_datum.findData(value))
                self.assertEqual(desk.place_datum.currentData(),value)
                self.assertEqual(desk.settings.value('map/gcj',type=bool),value)
                self.assertEqual(desk.coords(),(31.2304,121.4737))
                self.assertEqual(desk.map.marker,desk.coords())
                self.assertEqual(desk.map.origin(),origin)
            x,y=project(31.2304,121.4737,desk.map.z)
            left,top=desk.map.origin()
            self.assertAlmostEqual(left+desk.map.width()/2,x)
            self.assertAlmostEqual(top+desk.map.height()/2,y)
        finally:
            desk.settings.clear()
            desk.closed=True; desk.close()
            desk.jobs.loop.call_soon_threadsafe(desk.jobs.loop.stop)
            desk.jobs.thread.join(timeout=2); desk.jobs.loop.close()

    def test_dropdown_navigation_survives_discovery_refresh(self):
        from PySide6 import QtTest as T
        app=W.QApplication.instance() or W.QApplication([])
        app.setOrganizationName('Everywhere-test')
        app.setApplicationName('ui-dropdown-test')
        desk=Desk()
        desk.map.fetch=lambda _:None
        rows=[dict(id='AA:01',name='Phone'),dict(id='AA:02',name='Phone')]
        desk.bt.scan=AsyncMock(side_effect=[rows,rows,rows[:1],rows])
        desk.connect_selected=Mock()
        def settle():
            deadline=time.monotonic()+3
            while desk.scanning and time.monotonic()<deadline:
                app.processEvents()
                time.sleep(.005)
            app.processEvents()
            self.assertFalse(desk.scanning)
        try:
            desk.show(); desk.enter('classic'); settle()
            field=desk.devices
            field.setCurrentIndex(0)
            T.QTest.keyClick(field,C.Qt.Key_Down)
            view=field.view()
            self.assertTrue(view.isVisible())
            T.QTest.keyClick(view,C.Qt.Key_Down)
            self.assertEqual(view.currentIndex().row(),1)
            desk.auto_scan(); settle()
            self.assertTrue(view.isVisible())
            self.assertEqual(view.currentIndex().row(),1)
            self.assertEqual(field.currentData(),'AA:01')
            T.QTest.keyClick(view,C.Qt.Key_Escape)
            desk.connect_selected.assert_not_called()
            self.assertFalse(view.isVisible())
            field.showPopup(); desk.auto_scan(); settle()
            self.assertFalse(view.isVisible())
            desk.connect_selected.assert_not_called()
            desk.auto_scan(); settle(); field.showPopup()
            T.QTest.keyClick(view,C.Qt.Key_Down)
            T.QTest.keyClick(view,C.Qt.Key_Return)
            desk.connect_selected.assert_called_once()
            self.assertEqual(field.currentData(),'AA:02')
            desk.connect_selected.reset_mock()
            field.showPopup()
            rect=view.visualRect(field.model().index(0,0))
            T.QTest.mouseClick(view.viewport(),C.Qt.LeftButton,pos=rect.center())
            app.processEvents()
            desk.connect_selected.assert_called_once()
            self.assertEqual(field.currentData(),'AA:01')
        finally:
            desk.closed=True; desk.close()
            desk.jobs.loop.call_soon_threadsafe(desk.jobs.loop.stop)
            desk.jobs.thread.join(timeout=2); desk.jobs.loop.close()

    def test_place_search_with_real_qt_replies(self):
        import json
        from tempfile import TemporaryDirectory
        from urllib.parse import parse_qs, urlsplit
        from unittest.mock import patch
        from PySide6 import QtNetwork as N
        from place_browser import PlaceBrowser

        app=W.QApplication.instance() or W.QApplication([])
        app.setOrganizationName('Everywhere-test')
        app.setApplicationName('ui-search-test')
        desk=Desk()
        browser=PlaceBrowser(desk,'search')
        browser.open()
        try:
            with TemporaryDirectory() as directory:
                resource=Path(directory)/'response.json'
                def lookup(url):
                    self.assertEqual(parse_qs(urlsplit(url).query)['q'],['上海 人民广场'])
                    return N.QNetworkRequest(C.QUrl.fromLocalFile(str(resource)))
                def search(data):
                    if data is None: resource.unlink(missing_ok=True)
                    else: resource.write_text(json.dumps(data),encoding='utf-8')
                    desk.last_query=0
                    browser.query.setText('上海 人民广场')
                    browser.submit.click()
                    deadline=time.monotonic()+3
                    while browser.reply is not None and time.monotonic()<deadline:
                        app.processEvents()
                    self.assertIsNone(browser.reply)
                with patch('place_browser.request',side_effect=lookup):
                    search([])
                    self.assertIn('未找到地点',browser.empty.text())
                    search({'error':'invalid response'})
                    self.assertIn('无法读取搜索结果',browser.empty.text())
                    search(None)
                    self.assertIn('无法连接地点服务',browser.empty.text())
                    search([{},dict(display_name='上海人民广场',lat='31.23',lon='121.47')])
                    self.assertEqual(browser.items.count(),1)
                    self.assertFalse(browser.empty.isVisible())
                    desk.send=Mock()
                    browser.items.itemClicked.emit(browser.items.item(0))
                    self.assertEqual(desk.place_title.text(),'上海人民广场')
                    self.assertEqual(desk.coords(),(31.23,121.47))
                    desk.send.assert_not_called()
        finally:
            desk.closed=True; desk.close()
            desk.jobs.loop.call_soon_threadsafe(desk.jobs.loop.stop)
            desk.jobs.thread.join(timeout=2); desk.jobs.loop.close()
