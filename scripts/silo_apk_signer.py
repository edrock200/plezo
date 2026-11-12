#!/usr/bin/env python3
"""Prints the SHA-256 of the certificate that signed an APK (APK Signature Scheme v3, else v2).

  silo_apk_signer.py <apk>

The output matches the "Signer #1 certificate SHA-256 digest" line of `apksigner verify
--print-certs`. Preview builds compare it with the previous release's APK: a different
certificate means Android will not install the new preview over the old one. Exits 2 when the
APK has no v2/v3 signature block (unsigned, or signed with v1 only).
"""

import hashlib
import struct
import sys

V2_ID = 0x7109871A
V3_ID = 0xF05368C0
MAGIC = b"APK Sig Block 42"


def _prefixed(buf: bytes, offset: int) -> tuple[bytes, int]:
    (size,) = struct.unpack_from("<I", buf, offset)
    start = offset + 4
    if start + size > len(buf):
        raise ValueError("truncated length-prefixed field")
    return buf[start : start + size], start + size


def signer_cert_sha256(data: bytes) -> str | None:
    eocd = data.rfind(b"PK\x05\x06")
    if eocd < 0:
        raise ValueError("not a zip file")
    (central_dir,) = struct.unpack_from("<I", data, eocd + 16)
    if central_dir < 24 or data[central_dir - 16 : central_dir] != MAGIC:
        return None
    (block_size,) = struct.unpack_from("<Q", data, central_dir - 24)
    # The block is [size u64][pairs...][size u64][magic]; the pairs start after the first size.
    pos, end = central_dir - block_size, central_dir - 24
    pairs = {}
    while pos < end:
        (size,) = struct.unpack_from("<Q", data, pos)
        (pair_id,) = struct.unpack_from("<I", data, pos + 8)
        pairs[pair_id] = data[pos + 12 : pos + 8 + size]
        pos += 8 + size
    for pair_id in (V3_ID, V2_ID):
        value = pairs.get(pair_id)
        if value is None:
            continue
        signers, _ = _prefixed(value, 0)
        signer, _ = _prefixed(signers, 0)
        signed_data, _ = _prefixed(signer, 0)
        _digests, offset = _prefixed(signed_data, 0)
        certificates, _ = _prefixed(signed_data, offset)
        certificate, _ = _prefixed(certificates, 0)
        return hashlib.sha256(certificate).hexdigest()
    return None


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 1
    with open(sys.argv[1], "rb") as f:
        digest = signer_cert_sha256(f.read())
    if digest is None:
        print(f"{sys.argv[1]} has no v2/v3 APK signature.", file=sys.stderr)
        return 2
    print(digest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
