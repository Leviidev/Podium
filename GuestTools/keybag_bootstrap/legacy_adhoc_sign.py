#!/usr/bin/env python3
"""Ad-hoc code signature in the format iOS 6's kernel understands.

Modern `codesign` emits CodeDirectory v0x20400 superblobs with SHA-256
alternates; iOS 6's AMFI finds no usable signature in those ("hook..execve()
killing pid N: no code signature"). This writes the classic layout instead:
the same superblob shape as the rootfs's own ad-hoc binaries (keybagd's, for
one): a SHA-1 CodeDirectory (v0x20100, ad-hoc) with five special slots, an
empty requirements set, an entitlements blob, and an empty CMS wrapper,
written into space reserved by `codesign_allocate`.

Usage: legacy_adhoc_sign.py <binary with LC_CODE_SIGNATURE> <identifier> [entitlements.plist]
"""
import hashlib
import struct
import sys

LC_CODE_SIGNATURE = 0x1D
PAGE = 4096


def blob(magic, payload):
    return struct.pack(">II", magic, 8 + len(payload)) + payload


def main(path, identifier, entitlements_path=None):
    data = bytearray(open(path, "rb").read())
    magic, _, _, _, ncmds, _, _ = struct.unpack_from("<7I", data, 0)
    assert magic == 0xFEEDFACE, "expects a thin 32-bit Mach-O"
    offset = 28
    signature = None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, offset)
        if cmd == LC_CODE_SIGNATURE:
            signature = struct.unpack_from("<II", data, offset + 8)
        offset += size
    assert signature, "run codesign_allocate first"
    data_offset, data_size = signature

    code_limit = data_offset
    code_hashes = [hashlib.sha1(data[i:min(i + PAGE, code_limit)]).digest() for i in range(0, code_limit, PAGE)]
    requirements = struct.pack(">III", 0xFADE0C01, 12, 0)
    entitlements = blob(0xFADE7171, open(entitlements_path, "rb").read() if entitlements_path else b"")
    empty_cms = blob(0xFADE0B01, b"")
    # Special slots in memory order -5…-1: entitlements, application
    # specific, resource directory, requirements, Info.plist.
    zero = b"\0" * 20
    special = [hashlib.sha1(entitlements).digest(), zero, zero, hashlib.sha1(requirements).digest(), zero]

    ident = identifier.encode() + b"\0"
    header_size = 48
    ident_offset = header_size
    hash_offset = ident_offset + len(ident) + 20 * len(special)
    length = hash_offset + 20 * len(code_hashes)
    code_directory = struct.pack(
        ">9I4BII",
        0xFADE0C02, length, 0x20100, 0x2,  # magic, length, version, flags = adhoc
        hash_offset, ident_offset, len(special), len(code_hashes), code_limit,
        20, 1, 0, 12,  # hashSize, hashType SHA-1, spare1, log2(pageSize)
        0, 0,  # spare2, scatterOffset
    ) + ident + b"".join(special) + b"".join(code_hashes)
    assert len(code_directory) == length

    parts = [(0, code_directory), (2, requirements), (5, entitlements), (0x10000, empty_cms)]
    index_size = 12 + 8 * len(parts)
    superblob = b""
    index = b""
    for slot, part in parts:
        index += struct.pack(">II", slot, index_size + len(superblob))
        superblob += part
    signature_blob = struct.pack(">III", 0xFADE0CC0, index_size + len(superblob), len(parts)) + index + superblob
    assert len(signature_blob) <= data_size, "codesign_allocate reserved too little space"
    data[data_offset:data_offset + len(signature_blob)] = signature_blob
    open(path, "wb").write(data)


if __name__ == "__main__":
    main(*sys.argv[1:4])
