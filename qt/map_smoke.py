"""Windows 单文件包通过回环 HTTPS 服务验证首屏地图瓦片。"""
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from ipaddress import ip_address
from pathlib import Path
import ssl
from tempfile import TemporaryDirectory
from threading import Thread
import time

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID
from PySide6 import QtCore as C, QtGui as G, QtNetwork as N, QtWidgets as W


def check_map_https(window):
    """在打包自检进程信任临时回环证书，等待地图完成一次真实的 HTTPS 请求和 PNG 解码。"""
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Everywhere map self-test")])
    now = datetime.now(timezone.utc)
    certificate = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
                   .public_key(key.public_key()).serial_number(x509.random_serial_number())
                   .not_valid_before(now - timedelta(minutes=5)).not_valid_after(now + timedelta(hours=1))
                   .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
                   .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ip_address("127.0.0.1"))]),
                                  critical=False).sign(key, hashes.SHA256()))
    pem = certificate.public_bytes(serialization.Encoding.PEM)
    image = G.QImage(256, 256, G.QImage.Format_RGB32)
    image.fill(G.QColor("#335577"))
    buffer = C.QBuffer()
    buffer.open(C.QIODevice.WriteOnly)
    if not image.save(buffer, "PNG"):
        raise RuntimeError("Qt cannot encode the map fixture")
    payload = bytes(buffer.data())

    class TileHandler(BaseHTTPRequestHandler):
        def setup(self):
            """在请求线程完成握手，空闲连接最多等待 5 秒。"""
            self.request.settimeout(5)
            self.request.do_handshake()
            super().setup()

        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(payload)

    with TemporaryDirectory() as folder, ThreadingHTTPServer(("127.0.0.1", 0), TileHandler) as server:
        chain = Path(folder) / "loopback.pem"
        chain.write_bytes(pem + key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                                  serialization.NoEncryption()))
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(chain)
        # accept 只接收连接，避免未完成的 TLS 握手阻塞 serve_forever 的退出。
        server.socket = context.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)
        original = N.QSslConfiguration.defaultConfiguration()
        config = N.QSslConfiguration(original)
        config.addCaCertificate(N.QSslCertificate(pem))
        N.QSslConfiguration.setDefaultConfiguration(config)
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            view = window.map
            view.net.setProxy(N.QNetworkProxy(N.QNetworkProxy.NoProxy))
            view.net.setCache(None)
            view.cache = None
            view.layer(f"https://127.0.0.1:{server.server_port}/{{z}}/{{x}}/{{y}}.png", "")
            window.stack.setCurrentIndex(1)
            window.show()
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                W.QApplication.processEvents()
                if view.tiles:
                    print("Windows map received and decoded a tile over HTTPS", flush=True)
                    return
                if view.failed:
                    raise RuntimeError(f"Windows map HTTPS request failed: {next(iter(view.failed.values()))[2]}")
                time.sleep(.01)
            raise RuntimeError("Windows map did not load its first tile within 15 seconds")
        finally:
            window.hide()
            window.stack.setCurrentIndex(0)
            server.shutdown()
            thread.join()
            N.QSslConfiguration.setDefaultConfiguration(original)
