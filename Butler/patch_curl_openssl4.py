#!/usr/bin/env python3
"""Patch Merging_RAVENNA_Daemon for modern Debian/Ubuntu libcurl.

Merging Butler 1.1 build 93 requires the symbol version CURL_OPENSSL_3.
Modern Ubuntu libcurl exports the same curl_easy_* API under CURL_OPENSSL_4.
Changing only the string is insufficient because ELF .gnu.version_r also stores
an ELF hash for the version name.  This tool updates both fields in a copy of
the executable and never modifies the original binary in place.
"""

from pathlib import Path
import argparse
import os
import shutil
import struct
import sys

OLD = b"CURL_OPENSSL_3"
NEW = b"CURL_OPENSSL_4"


def elf_hash(value: bytes) -> int:
    h = 0
    for c in value:
        h = (h << 4) + c
        g = h & 0xF0000000
        if g:
            h ^= g >> 24
        h &= ~g
    return h & 0xFFFFFFFF


def patch(src: Path, dst: Path) -> None:
    if src.resolve() == dst.resolve():
        raise SystemExit("Refusing to patch the original binary in place")
    if not src.is_file():
        raise SystemExit(f"Input file not found: {src}")
    if len(OLD) != len(NEW):
        raise SystemExit("Internal error: version strings have different lengths")

    shutil.copy2(src, dst)
    data = bytearray(dst.read_bytes())

    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise SystemExit("Expected a 64-bit little-endian ELF executable")

    e_shoff = struct.unpack_from("<Q", data, 0x28)[0]
    e_shentsize = struct.unpack_from("<H", data, 0x3A)[0]
    e_shnum = struct.unpack_from("<H", data, 0x3C)[0]
    e_shstrndx = struct.unpack_from("<H", data, 0x3E)[0]

    def shdr(index: int):
        off = e_shoff + index * e_shentsize
        return struct.unpack_from("<IIQQQQIIQQ", data, off)

    shstr = shdr(e_shstrndx)
    shstr_off = shstr[4]

    def cstring(off: int) -> bytes:
        end = data.index(0, off)
        return bytes(data[off:end])

    sections = []
    for i in range(e_shnum):
        section = shdr(i)
        name = cstring(shstr_off + section[0]).decode(errors="replace")
        sections.append((name, section))

    verneed = None
    for name, section in sections:
        if name == ".gnu.version_r":
            verneed = section
            break
    if verneed is None:
        raise SystemExit("ELF has no .gnu.version_r section")

    verneed_off = verneed[4]
    verneed_size = verneed[5]
    dynstr_index = verneed[6]
    dynstr = sections[dynstr_index][1]
    dynstr_off = dynstr[4]

    old_hash = elf_hash(OLD)
    new_hash = elf_hash(NEW)
    patched = 0
    vn_rel = 0

    while vn_rel < verneed_size:
        vn_off = verneed_off + vn_rel
        _vn_version, vn_cnt, vn_file, vn_aux, vn_next = struct.unpack_from(
            "<HHIII", data, vn_off
        )
        libname = cstring(dynstr_off + vn_file)
        aux_rel = vn_aux

        for _ in range(vn_cnt):
            aux_off = vn_off + aux_rel
            vna_hash, _flags, _other, vna_name, vna_next = struct.unpack_from(
                "<IHHII", data, aux_off
            )
            version = cstring(dynstr_off + vna_name)

            if libname == b"libcurl.so.4" and version == OLD:
                if vna_hash != old_hash:
                    raise SystemExit(
                        f"Unexpected ELF version hash 0x{vna_hash:08x}; "
                        f"expected 0x{old_hash:08x}"
                    )
                struct.pack_into("<I", data, aux_off, new_hash)
                name_off = dynstr_off + vna_name
                data[name_off : name_off + len(OLD)] = NEW
                patched += 1

            if vna_next == 0:
                break
            aux_rel += vna_next

        if vn_next == 0:
            break
        vn_rel += vn_next

    if patched != 1:
        raise SystemExit(
            f"Expected one libcurl version requirement to patch, found {patched}"
        )

    dst.write_bytes(data)
    os.chmod(dst, src.stat().st_mode | 0o100)

    print(f"Patched: {dst}")
    print(f"Version: {OLD.decode()} -> {NEW.decode()}")
    print(f"ELF hash: 0x{old_hash:08x} -> 0x{new_hash:08x}")
    print("Original binary was left unchanged.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "input",
        nargs="?",
        default="Merging_RAVENNA_Daemon",
        help="original Butler executable",
    )
    parser.add_argument(
        "output",
        nargs="?",
        default="Merging_RAVENNA_Daemon.curl4",
        help="patched output executable",
    )
    args = parser.parse_args()
    patch(Path(args.input), Path(args.output))


if __name__ == "__main__":
    main()
