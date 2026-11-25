"""Verify the response format with a disposable self-signed test identity."""
import base64
import datetime as dt
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from cryptography import x509
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import ec,utils
from cryptography.hazmat.primitives.serialization import pkcs7
from cryptography.x509.oid import NameOID

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import worker

class Signer(unittest.TestCase):
    def test_digest_signed_once_and_mismatched_key_rejected(self):
        key=ec.generate_private_key(ec.SECP256R1())
        dn=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'Everywhere temporary test')])
        now=dt.datetime.now(dt.timezone.utc)
        cert=(x509.CertificateBuilder().subject_name(dn).issuer_name(dn)
              .public_key(key.public_key()).serial_number(1).not_valid_before(now)
              .not_valid_after(now+dt.timedelta(days=1)).sign(key,hashes.SHA256()))
        der=pkcs7.serialize_certificates([cert],serialization.Encoding.DER)
        digest=hashlib.sha256(b'unit test').digest()
        requests=[dict(op='certificate'),dict(op='sign',challenge=base64.b64encode(digest).decode())]
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)
            (p/'certificate.p7b').write_bytes(der)
            for match,private in [(True,key),(False,ec.generate_private_key(ec.SECP256R1()))]:
                (p/'identity.pk8').write_bytes(private.private_bytes(serialization.Encoding.DER,
                                      serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
                inp=io.TextIOWrapper(io.BytesIO(('\n'.join(map(json.dumps,requests))+'\n').encode()))
                out=io.StringIO()
                with patch.object(sys,'executable',str(p/'worker.exe')),patch.object(sys,'stdin',inp),patch.object(sys,'stdout',out),patch.dict(os.environ,{'EVERYWHERE_MFI_KEY':str(p/'identity.pk8')}):
                    worker.sign_service()
                certificate,signature=map(json.loads,out.getvalue().splitlines())
                self.assertEqual(base64.b64decode(certificate['certificate']),der)
                if match:
                    raw=base64.b64decode(signature['signature'])
                    self.assertEqual(len(raw),64)
                    sig=utils.encode_dss_signature(int.from_bytes(raw[:32],'big'),int.from_bytes(raw[32:],'big'))
                    key.public_key().verify(sig,digest,ec.ECDSA(utils.Prehashed(hashes.SHA256())))
                else:self.assertIn('error',signature)
