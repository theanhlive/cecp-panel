#!/usr/bin/env python3
"""TEST ONLY: make minisign-format keys/signatures with openssl, so the integration scenario
does not depend on the minisign package. Real releases are signed with `minisign -S` offline.

  minisign_sign.py genkey PUB_FILE SECRET_PEM
  minisign_sign.py sign SECRET_PEM MESSAGE SIG_FILE [TRUSTED_COMMENT]
"""
import base64
import hashlib
import os
import subprocess
import sys
import tempfile


def run(*args, **kw):
    return subprocess.run(list(args), check=True, stdout=subprocess.PIPE, **kw).stdout


def genkey(pub_path, sec_path):
    run("openssl", "genpkey", "-algorithm", "ed25519", "-out", sec_path)
    os.chmod(sec_path, 0o600)
    der = run("openssl", "pkey", "-in", sec_path, "-pubout", "-outform", "DER")
    key_id = os.urandom(8)
    with open(sec_path + ".id", "wb") as f:
        f.write(key_id)
    with open(pub_path, "w") as f:
        f.write("untrusted comment: cecp-panel TEST key\n")
        f.write(base64.b64encode(b"Ed" + key_id + der[-32:]).decode() + "\n")


def ed25519_sign(sec_path, data):
    with tempfile.NamedTemporaryFile() as tmp:
        tmp.write(data)
        tmp.flush()
        return run("openssl", "pkeyutl", "-sign", "-inkey", sec_path, "-rawin", "-in", tmp.name)


def sign(sec_path, msg_path, sig_path, comment):
    with open(sec_path + ".id", "rb") as f:
        key_id = f.read()
    with open(msg_path, "rb") as f:
        digest = hashlib.blake2b(f.read(), digest_size=64).digest()
    sig = ed25519_sign(sec_path, digest)
    global_sig = ed25519_sign(sec_path, sig + comment.encode())
    with open(sig_path, "w") as f:
        f.write("untrusted comment: signature from cecp-panel TEST key\n")
        f.write(base64.b64encode(b"ED" + key_id + sig).decode() + "\n")
        f.write("trusted comment: " + comment + "\n")
        f.write(base64.b64encode(global_sig).decode() + "\n")


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "genkey":
        genkey(sys.argv[2], sys.argv[3])
    elif len(sys.argv) in (5, 6) and sys.argv[1] == "sign":
        sign(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] if len(sys.argv) == 6 else "cecp-panel test")
    else:
        sys.exit(__doc__)
