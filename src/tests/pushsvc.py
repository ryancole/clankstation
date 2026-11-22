"""A stand-in push service and phone for the S6 VM test.

It makes a Web Push subscription (a P-256 key pair and an auth secret),
writes it to /tmp/sub.json, and serves HTTP on :9000. Each push it receives
is decrypted (RFC 8291, aes128gcm) like a phone would, and the notification
JSON is appended to /tmp/got.jsonl.
"""

import base64
import hashlib
import hmac
import json
import os
import struct
from http.server import BaseHTTPRequestHandler, HTTPServer

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDFExpand


def b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


key = ec.generate_private_key(ec.SECP256R1())
pub = key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
auth = os.urandom(16)
with open("/tmp/sub.json", "w") as f:
    json.dump({"endpoint": "http://pushsvc:9000/send/phone1", "keys": {"p256dh": b64(pub), "auth": b64(auth)}}, f)


def expand(prk, info, n):
    return HKDFExpand(hashes.SHA256(), n, info).derive(prk)


def extract(salt, ikm):
    return hmac.new(salt, ikm, hashlib.sha256).digest()


def decrypt(body):
    salt, rs, idlen = body[:16], struct.unpack(">I", body[16:20])[0], body[20]
    as_pub, ct = body[21:21 + idlen], body[21 + idlen:]
    assert len(ct) <= rs, "record bigger than its record size"
    peer = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), as_pub)
    shared = key.exchange(ec.ECDH(), peer)
    ikm = expand(extract(auth, shared), b"WebPush: info\x00" + pub + as_pub, 32)
    prk = extract(salt, ikm)
    cek = expand(prk, b"Content-Encoding: aes128gcm\x00", 16)
    nonce = expand(prk, b"Content-Encoding: nonce\x00", 12)
    pt = AESGCM(cek).decrypt(nonce, ct, None).rstrip(b"\x00")
    assert pt.endswith(b"\x02"), "no last-record delimiter"
    return pt[:-1]


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        ok = self.headers.get("Authorization", "").startswith("vapid t=") and \
            self.headers.get("Content-Encoding") == "aes128gcm"
        note = json.loads(decrypt(body)) if ok else {"error": "bad headers"}
        with open("/tmp/got.jsonl", "a") as f:
            f.write(json.dumps(note) + "\n")
        self.send_response(201)
        self.end_headers()

    def log_message(self, *a):
        pass


HTTPServer(("0.0.0.0", 9000), H).serve_forever()
