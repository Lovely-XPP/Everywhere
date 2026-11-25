"""Console entry point for the pre-existing accessory client and its private, local signing provider."""
import base64
import json
import os
from pathlib import Path
import sys


def sign_service():
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec, utils
    from cryptography.hazmat.primitives.serialization.pkcs7 import load_der_pkcs7_certificates
    root = Path(sys.executable).parent
    if (root/'asset'/'mfi').is_dir():
        root = root/'asset'/'mfi'
    certificate = (root/'certificate.p7b').read_bytes()
    default = root/'identity.pk8'
    if not default.is_file():
        default = Path(os.environ['LOCALAPPDATA'])/'Everywhere'/'MFi'/'identity.pk8'
    key_path = Path(os.environ.get('EVERYWHERE_MFI_KEY', default))
    key = None
    for line in sys.stdin.buffer:
        try:
            req = json.loads(line)
            if req['op'] == 'certificate':
                reply = dict(type='mfi', certificate=base64.b64encode(certificate).decode())
            elif req['op'] == 'sign':
                if key is None:
                    candidate = serialization.load_der_private_key(key_path.read_bytes(), None)
                    if not isinstance(candidate, ec.EllipticCurvePrivateKey) or not isinstance(candidate.curve,ec.SECP256R1):
                        raise ValueError('需要 P-256 配件身份')
                    if not any(c.public_key()==candidate.public_key() for c in load_der_pkcs7_certificates(certificate)):
                        raise ValueError('证书与私钥不匹配')
                    key=candidate
                digest=base64.b64decode(req['challenge'],validate=True)
                signature=key.sign(digest,ec.ECDSA(utils.Prehashed(hashes.SHA256())))
                raw=b''.join(i.to_bytes(32,'big') for i in utils.decode_dss_signature(signature))
                reply=dict(signature=base64.b64encode(raw).decode())
            else:
                raise ValueError('不支持的签名操作')
        except Exception as exc:
            reply=dict(error=str(exc))
        print(json.dumps(reply),flush=True)


if __name__=='__main__':
    if sys.argv[1:2] == ['--self-test']:
        from accessory_location.cli import main
        from cryptography.hazmat.primitives.asymmetric import ec
        assert callable(main) and ec.SECP256R1().key_size == 256
        print("iAP2 worker ready")
    elif sys.argv[1:2] == ['--verify-bundle']:
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric import ec
        from cryptography.hazmat.primitives.serialization.pkcs7 import load_der_pkcs7_certificates
        identity = Path(sys.executable).parent/'asset'/'mfi'
        key = serialization.load_der_private_key((identity/'identity.pk8').read_bytes(), None)
        certificates = load_der_pkcs7_certificates((identity/'certificate.p7b').read_bytes())
        if not isinstance(key, ec.EllipticCurvePrivateKey) or not isinstance(key.curve, ec.SECP256R1) or not any(
                certificate.public_key() == key.public_key() for certificate in certificates):
            raise ValueError("配件证书与签名身份不匹配")
    elif len(sys.argv)==1:
        sign_service()
    else:
        from accessory_location.cli import main
        main()
