"""Drive the viewport with delayed Qt replies, including replies delivered after cancellation."""
import os
from pathlib import Path
import sys
import time
import unittest
from unittest.mock import Mock

os.environ.setdefault('QT_QPA_PLATFORM','offscreen')
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
try:
    from PySide6 import QtCore as C, QtGui as G, QtNetwork as N, QtWidgets as W
except ImportError as exc:
    raise unittest.SkipTest('Qt bindings are required for map tests') from exc
from geo import unproject
from mapview import MapView


class Reply(C.QObject):
    finished=C.Signal()

    def __init__(self,req,payload):
        super().__init__()
        self.url=req.url().toString()
        self.payload=payload
        self.cancelled=False
        self.result=N.QNetworkReply.NoError

    def abort(self):
        self.cancelled=True

    def error(self):
        return self.result

    def errorString(self):
        return self.result.name

    def readAll(self):
        return self.payload

    def rawHeader(self,name):
        return b''


class MapRefresh(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app=W.QApplication.instance() or W.QApplication([])

    def setUp(self):
        self.view=MapView()
        self.view.resize(400,300)
        pix=G.QPixmap(256,256)
        pix.fill(G.QColor('#335577'))
        buffer=C.QBuffer()
        buffer.open(C.QIODevice.WriteOnly)
        pix.save(buffer,'PNG')
        self.payload=buffer.data()
        self.requests=[]
        def get(req):
            reply=Reply(req,self.payload)
            self.requests.append(reply)
            return reply
        self.view.net=Mock(get=get)
        self.view.show()
        self.wait(lambda:bool(self.view.pending))

    def tearDown(self):
        self.view.close()
        self.app.processEvents()

    def wait(self,condition,seconds=1):
        end=time.monotonic()+seconds
        while not condition() and time.monotonic()<end:
            self.app.processEvents()
            time.sleep(.004)
        self.assertTrue(condition())

    def fill(self):
        def filled():
            for reply in list(self.view.pending.values()):
                reply.finished.emit()
            return {r[0] for r in self.view.visible_tiles()}<=self.view.tiles.keys()
        self.wait(filled)

    def test_refresh_is_bounded_and_scoped_to_visible_layer(self):
        v=self.view
        old=list(v.pending.values())
        self.assertLessEqual(len(old),4)
        v.layer('https://example.invalid/{z}/{x}/{y}','test')
        self.wait(lambda:all(r.cancelled for r in old))
        for r in old: r.finished.emit()
        self.fill()
        self.assertFalse(any(r.url in v.tiles or r.url in v.failed for r in old))
        count=len(self.requests)
        v.grab(); v.update(); self.app.processEvents()
        self.assertEqual(len(self.requests),count)
        v.refresh_tiles()
        self.wait(lambda:bool(v.pending))
        self.assertLessEqual(len(v.pending),4)
        self.assertTrue(v.pending.keys()<=v.tiles.keys())
        pending=list(v.pending.values())
        v.hide()
        self.assertTrue(all(r.cancelled for r in pending))
        self.assertFalse(v.scheduler.isActive())
        v.show(); self.wait(lambda:bool(v.pending))
        for r in pending: r.finished.emit()
        self.assertTrue(v.pending)

    def test_failed_tile_retries_without_another_interaction(self):
        v=self.view
        reply=next(iter(v.pending.values()))
        url=reply.url
        reply.result=N.QNetworkReply.TimeoutError
        reply.finished.emit()
        def retried():
            for key,r in list(v.pending.items()):
                if key!=url: r.finished.emit()
            return url in v.pending
        self.wait(retried,4)
        self.assertEqual(sum(r.url==url for r in self.requests),2)
        v.pending[url].finished.emit()
        self.assertNotIn(url,v.failed)
        self.assertIn(url,v.tiles)

    def test_zoom_keeps_cursor_coordinate_and_uses_cached_preview(self):
        self.fill()
        v=self.view
        anchor=C.QPointF(120,95)
        def at_cursor():
            x,y=v.origin()
            return unproject(x+anchor.x(),y+anchor.y(),v.z)
        before=at_cursor()
        v.zoom(1,anchor)
        after=at_cursor()
        for a,b in zip(before,after): self.assertAlmostEqual(a,b,places=8)
        self.assertEqual(v.grab().toImage().pixelColor(anchor.toPoint()).name(),'#335577')
        self.wait(lambda:bool(v.pending))
        self.fill()
        v.choose((23.109,113.319),span=.025)
        self.assertEqual(v.center,(23.109,113.319))
        self.assertGreater(v.z,12)
