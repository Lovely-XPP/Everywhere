"""Check modal ownership, keyboard dismissal and explicit commits with actual Qt windows."""
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock

os.environ.setdefault('QT_QPA_PLATFORM','offscreen')
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
try:
    from PySide6 import QtCore as C, QtTest as T, QtWidgets as W
except ImportError as exc:
    raise unittest.SkipTest('Qt bindings required') from exc

from app import Desk
from dialogs import choose_program, custom_layer
from place_browser import PlaceBrowser


class ModalWorkflow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app=W.QApplication.instance() or W.QApplication([])
        cls.app.setOrganizationName('Everywhere-test'); cls.app.setApplicationName('ui-modals')

    def setUp(self):
        self.desk=Desk()
        self.desk.map.fetch=lambda _:None
        self.desk.show()
        self.app.processEvents()

    def tearDown(self):
        self.desk.closed=True; self.desk.close()
        self.desk.jobs.loop.call_soon_threadsafe(self.desk.jobs.loop.stop)
        self.desk.jobs.thread.join(timeout=2); self.desk.jobs.loop.close()

    def drive(self,show,interact,parent=None):
        errors=[]
        def inspect():
            dialog=self.app.activeModalWidget()
            try:
                self.assertIsInstance(dialog,W.QDialog)
                self.assertEqual(dialog.windowModality(),C.Qt.ApplicationModal)
                self.assertIs(dialog.parentWidget(),parent or self.desk)
                self.assertTrue(dialog.backdrop.isVisible())
                interact(dialog)
            except Exception as exc:
                errors.append(exc)
            finally:
                if dialog is not None and dialog.isVisible(): dialog.reject()
        C.QTimer.singleShot(0,inspect)
        result=show()
        if errors: raise errors[0]
        return result

    def test_send_requires_explicit_acceptance(self):
        for key in (C.Qt.Key_Escape,C.Qt.Key_Return):
            self.assertFalse(self.drive(self.desk.confirm_send,lambda d:T.QTest.keyClick(d,key)))
        self.assertFalse(self.drive(self.desk.confirm_send,lambda d:d.close()))
        self.assertTrue(self.drive(self.desk.confirm_send,lambda d:d.findChild(W.QPushButton,'dialogPrimary').click()))

    def test_nested_place_editor_returns_to_browser(self):
        self.desk.places('favorites')
        book=self.app.activeModalWidget()
        self.assertIsInstance(book,PlaceBrowser)
        self.assertEqual(book.windowModality(),C.Qt.ApplicationModal)
        self.desk.remember=Mock()
        show=lambda:self.desk.name_place((31.,121.),'上海',parent=book)
        self.drive(show,lambda d:T.QTest.keyClick(d,C.Qt.Key_Escape),book)
        self.desk.remember.assert_not_called()
        self.assertIs(self.app.activeModalWidget(),book)
        self.assertTrue(book.backdrop.isVisible())
        def edit(dialog):
            field=dialog.findChild(W.QLineEdit)
            field.setText('  ')
            accept=dialog.findChild(W.QPushButton,'dialogPrimary')
            self.assertFalse(accept.isEnabled())
            field.setText(' 人民广场 ')
            accept.click()
        self.drive(show,edit,book)
        self.desk.remember.assert_called_once_with('favorites','人民广场',(31.,121.))
        book.reject()
        self.assertIsNone(self.app.activeModalWidget())

    def test_layer_and_program_selection(self):
        def fill(dialog):
            url,credit=dialog.findChildren(W.QLineEdit)
            submit=dialog.findChild(W.QPushButton,'dialogPrimary')
            credit.setText('Test')
            url.setText('https://example.invalid/map')
            self.assertFalse(submit.isEnabled())
            url.setText('https://example.invalid/{z}/{x}/{y}')
            dialog.findChild(W.QComboBox).setCurrentIndex(1)
            self.assertTrue(submit.isEnabled())
            submit.click()
        self.assertEqual(self.drive(lambda:custom_layer(self.desk),fill),('https://example.invalid/{z}/{x}/{y}','Test',True))
        self.assertIsNone(self.drive(lambda:choose_program(self.desk),lambda d:d.reject()))
