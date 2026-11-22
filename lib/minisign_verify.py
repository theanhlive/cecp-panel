#!/usr/bin/env python3
"""Verify a minisign signature with openssl (fallback when the `minisign` binary is missing).

Usage: minisign_verify.py PUBKEY_FILE SIG_FILE MESSAGE_FILE
Exit 0 and print the trusted comment on success; exit 1 with a reason on stderr otherwise.

Format (https://jedisct1.github.io/minisign/):
  public key  = base64("Ed" | key_id[8] | ed25519_pk[32])
  signature   = base64(alg[2] | key_id[8] | ed25519_sig[64]); alg "ED" signs BLAKE2b-512(file),
                legacy "Ed" signs the file itself
  global sig  = ed25519 over (signature[64] | trusted comment), so the comment is authenticated too
Ed25519 itself is checked by `openssl pkeyutl -verify -rawin` (OpenSSL >= 3.0).
"""
import base64
import binascii
import hashlib
import os
import re
import subprocess
import sys
import tempfile

ED25519_SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")
TRUSTED = "trusted comment: "


def fail(msg):
    sys.stderr.write("minisign_verify: %s\n" % msg)
    sys.exit(1)


def b64(line, size, what):
    try:
        raw = base64.b64decode(line.strip(), validate=True)
    except (binascii.Error, ValueError):
        fail("%s is not valid base64" % what)
    if len(raw) != size:
        fail("%s has %d bytes, expected %d" % (what, len(raw), size))
    return raw


def read_pubkey(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if re.fullmatch(r"RW[A-Za-z0-9+/]{54}", line.strip()):
                pk = b64(line, 42, "public key")
                if pk[:2] != b"Ed":
                    fail("unsupported public key algorithm")
                return pk[2:10], pk[10:]
    fail("no public key line in %s" % path)


def ed25519_ok(pk, sig, data, tmp):
    paths = {}
    for name, blob in (("pub.der", ED25519_SPKI_PREFIX + pk), ("sig", sig), ("data", data)):
        paths[name] = os.path.join(tmp, name)
        with open(paths[name], "wb") as f:
            f.write(blob)
    r = subprocess.run(
        ["openssl", "pkeyutl", "-verify", "-pubin", "-keyform", "DER", "-inkey", paths["pub.der"],
         "-rawin", "-in", paths["data"], "-sigfile", paths["sig"]],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    return r.returncode == 0


def main():
    if len(sys.argv) != 4:
        fail("usage: minisign_verify.py PUBKEY SIG MESSAGE")
    key_id, pk = read_pubkey(sys.argv[1])
    with open(sys.argv[2], encoding="utf-8", errors="replace") as f:
        lines = [ln.rstrip("\r\n") for ln in f]
    if len(lines) < 4 or not lines[2].startswith(TRUSTED):
        fail("malformed signature file")
    sig = b64(lines[1], 74, "signature")
    alg, sig_key_id, sig_bytes = sig[:2], sig[2:10], sig[10:]
    if sig_key_id != key_id:
        fail("signature was made with another key (key id %s, expected %s)"
             % (sig_key_id[::-1].hex().upper(), key_id[::-1].hex().upper()))
    with open(sys.argv[3], "rb") as f:
        data = f.read()
    if alg == b"ED":
        data = hashlib.blake2b(data, digest_size=64).digest()
    elif alg != b"Ed":
        fail("unsupported signature algorithm")
    trusted = lines[2][len(TRUSTED):]
    global_sig = b64(lines[3], 64, "global signature")
    with tempfile.TemporaryDirectory() as tmp:
        if not ed25519_ok(pk, sig_bytes, data, tmp):
            fail("signature verification failed")
        if not ed25519_ok(pk, global_sig, sig_bytes + trusted.encode("utf-8"), tmp):
            fail("trusted comment signature verification failed")
    print("Trusted comment: " + trusted)


if __name__ == "__main__":
    main()
