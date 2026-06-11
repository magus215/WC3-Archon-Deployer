"""Pure-Python MPQ archive reader for Warcraft III maps (.w3x / .w3m).

No native dependencies (no StormLib, no MPQEditor) -> works on any Python 3.7+,
any OS, any bitness. This is the read side of the deployer's MPQ layer.

Scope: enough of the MPQ v1 format to read the files inside a vanilla melee map
(war3map.j, war3map.w3i, the objdata files, gameplay constants). Files are looked
up by exact name via the hash table, so a (listfile) is not required.

References: the MPQ format as documented by Zezula (StormLib) and the wc3 modding
community. Decryption constants and the hash/crypt algorithms are the canonical ones.
"""

from __future__ import annotations

import bz2
import struct
import zlib
from dataclasses import dataclass

# --- MPQ signatures -------------------------------------------------------
MPQ_HEADER_SIG = 0x1A51504D       # 'MPQ\x1a'  -- real archive header
MPQ_USERDATA_SIG = 0x1B51504D     # 'MPQ\x1b'  -- user-data header (points to real one)

# --- Block (file) flags ---------------------------------------------------
FLAG_IMPLODE = 0x00000100         # compressed with PKWARE DCL (single method)
FLAG_COMPRESS = 0x00000200        # compressed with one or more methods (mask byte)
FLAG_ENCRYPTED = 0x00010000       # file is encrypted
FLAG_FIX_KEY = 0x00020000         # encryption key adjusted by file position+size
FLAG_SINGLE_UNIT = 0x01000000     # file stored as a single block, not sectored
FLAG_SECTOR_CRC = 0x04000000      # sector offset table has trailing CRC entry
FLAG_EXISTS = 0x80000000          # block entry is in use

HASH_ENTRY_DELETED = 0xFFFFFFFE
HASH_ENTRY_EMPTY = 0xFFFFFFFF


def _make_crypt_table():
    table = [0] * 0x500
    seed = 0x00100001
    for i in range(0x100):
        index = i
        for _ in range(5):
            seed = (seed * 125 + 3) % 0x2AAAAB
            t1 = (seed & 0xFFFF) << 0x10
            seed = (seed * 125 + 3) % 0x2AAAAB
            t2 = seed & 0xFFFF
            table[index] = (t1 | t2) & 0xFFFFFFFF
            index += 0x100
    return table


_CRYPT_TABLE = _make_crypt_table()

# Hash types passed to _hash()
HASH_TABLE_OFFSET = 0   # index into the hash table
HASH_NAME_A = 1         # first name verifier
HASH_NAME_B = 2         # second name verifier
HASH_FILE_KEY = 3       # base encryption key for a file


def _hash(string: str, hash_type: int) -> int:
    """Storm string hash. Used for hash-table lookup and file keys."""
    seed1 = 0x7FED7FED
    seed2 = 0xEEEEEEEE
    for ch in string.upper().replace("/", "\\"):
        c = ord(ch)
        seed1 = (_CRYPT_TABLE[(hash_type << 8) + c] ^ ((seed1 + seed2) & 0xFFFFFFFF)) & 0xFFFFFFFF
        seed2 = (c + seed1 + seed2 + (seed2 << 5) + 3) & 0xFFFFFFFF
    return seed1


def _decrypt(data: bytes, key: int) -> bytes:
    """Decrypt a buffer of 32-bit little-endian words with the given key."""
    n = len(data) // 4
    if n == 0:
        return b""
    words = list(struct.unpack("<%dI" % n, data[: n * 4]))
    seed1 = key & 0xFFFFFFFF
    seed2 = 0xEEEEEEEE
    for i in range(n):
        seed2 = (seed2 + _CRYPT_TABLE[0x400 + (seed1 & 0xFF)]) & 0xFFFFFFFF
        val = words[i]
        val = (val ^ ((seed1 + seed2) & 0xFFFFFFFF)) & 0xFFFFFFFF
        words[i] = val
        seed1 = (((~seed1 << 0x15) & 0xFFFFFFFF) + 0x11111111 | (seed1 >> 0x0B)) & 0xFFFFFFFF
        seed2 = (val + seed2 + (seed2 << 5) + 3) & 0xFFFFFFFF
    return struct.pack("<%dI" % n, *words) + data[n * 4 :]


def _encrypt(data: bytes, key: int) -> bytes:
    """Encrypt a buffer of 32-bit little-endian words (inverse of _decrypt)."""
    n = len(data) // 4
    if n == 0:
        return b""
    words = list(struct.unpack("<%dI" % n, data[: n * 4]))
    seed1 = key & 0xFFFFFFFF
    seed2 = 0xEEEEEEEE
    for i in range(n):
        seed2 = (seed2 + _CRYPT_TABLE[0x400 + (seed1 & 0xFF)]) & 0xFFFFFFFF
        plain = words[i]
        words[i] = (plain ^ ((seed1 + seed2) & 0xFFFFFFFF)) & 0xFFFFFFFF
        seed1 = (((~seed1 << 0x15) & 0xFFFFFFFF) + 0x11111111 | (seed1 >> 0x0B)) & 0xFFFFFFFF
        seed2 = (plain + seed2 + (seed2 << 5) + 3) & 0xFFFFFFFF  # seed2 advances on PLAINTEXT
    return struct.pack("<%dI" % n, *words) + data[n * 4 :]


def _decompress(data: bytes) -> bytes:
    """Decompress one MPQ sector given its leading compression-mask byte."""
    if not data:
        return data
    mask = data[0]
    body = data[1:]
    if mask == 0x02:           # zlib / deflate
        return zlib.decompress(body)
    if mask == 0x10:           # bzip2
        return bz2.decompress(body)
    if mask == 0x08:           # PKWARE DCL implode
        return _pkware_explode(body)
    if mask == 0x00:           # no compression flagged
        return body
    raise NotImplementedError(
        f"MPQ sector compression 0x{mask:02X} not supported yet "
        f"(only zlib 0x02, bzip2 0x10, pkware 0x08 implemented)"
    )


# PKWARE DCL "explode" is implemented lazily in pkware.py so this module stays
# focused; import is deferred so maps that never use it don't pay for it.
def _pkware_explode(data: bytes) -> bytes:
    from pkware import explode
    return explode(data)


@dataclass
class _Block:
    file_pos: int      # offset of file data, relative to archive start
    packed_size: int   # bytes actually stored
    unpacked_size: int # bytes after decompression
    flags: int


@dataclass
class _HashEntry:
    name_a: int
    name_b: int
    locale: int
    platform: int
    block_index: int


class MPQArchive:
    """Read-only MPQ archive reader. Open a .w3x/.w3m/.mpq and read files by name."""

    def __init__(self, path: str):
        self.path = path
        with open(path, "rb") as fh:
            self._data = fh.read()
        self._archive_offset = self._find_header()
        self._read_header()
        self._read_tables()

    # -- header / table loading -------------------------------------------
    def _find_header(self) -> int:
        """Locate the MPQ header. .w3x maps prepend a 512-byte HM3W header, and the
        archive itself begins on a 512-byte boundary; an optional user-data header
        may precede the real one."""
        data = self._data
        offset = 0
        while offset + 4 <= len(data):
            sig = struct.unpack_from("<I", data, offset)[0]
            if sig == MPQ_HEADER_SIG:
                return offset
            if sig == MPQ_USERDATA_SIG:
                # user-data header: dwHeaderOffset at +0x08 points to the real header
                hdr_off = struct.unpack_from("<I", data, offset + 0x08)[0]
                return offset + hdr_off
            offset += 0x200
        raise ValueError("No MPQ header found (not an MPQ/.w3x archive?)")

    def _read_header(self):
        base = self._archive_offset
        (sig, header_size, archive_size, fmt_version, sector_shift,
         hash_pos, block_pos, hash_count, block_count) = struct.unpack_from(
            "<IIIHHIIII", self._data, base)
        if sig != MPQ_HEADER_SIG:
            raise ValueError("bad MPQ header signature")
        self.format_version = fmt_version
        self.sector_size = 512 << sector_shift
        self._hash_pos = base + hash_pos
        self._block_pos = base + block_pos
        self._hash_count = hash_count
        self._block_count = block_count

    def _read_tables(self):
        hash_raw = self._data[self._hash_pos : self._hash_pos + self._hash_count * 16]
        hash_raw = _decrypt(hash_raw, _hash("(hash table)", HASH_FILE_KEY))
        self._hash_table = []
        for i in range(self._hash_count):
            a, b, loc, plat, blk = struct.unpack_from("<IIHHI", hash_raw, i * 16)
            self._hash_table.append(_HashEntry(a, b, loc, plat, blk))

        block_raw = self._data[self._block_pos : self._block_pos + self._block_count * 16]
        block_raw = _decrypt(block_raw, _hash("(block table)", HASH_FILE_KEY))
        self._block_table = []
        for i in range(self._block_count):
            pos, csize, usize, flags = struct.unpack_from("<IIII", block_raw, i * 16)
            self._block_table.append(_Block(self._archive_offset + pos, csize, usize, flags))

    # -- lookup ------------------------------------------------------------
    def _find_hash_entry(self, name: str):
        start = _hash(name, HASH_TABLE_OFFSET) & (self._hash_count - 1)
        name_a = _hash(name, HASH_NAME_A)
        name_b = _hash(name, HASH_NAME_B)
        i = start
        for _ in range(self._hash_count):
            entry = self._hash_table[i]
            if entry.block_index == HASH_ENTRY_EMPTY:
                return None
            if (entry.name_a == name_a and entry.name_b == name_b
                    and entry.block_index != HASH_ENTRY_DELETED):
                return entry
            i = (i + 1) & (self._hash_count - 1)
        return None

    def has_file(self, name: str) -> bool:
        return self._find_hash_entry(name) is not None

    def read_file(self, name: str) -> bytes:
        entry = self._find_hash_entry(name)
        if entry is None:
            raise KeyError(f"file not found in archive: {name}")
        block = self._block_table[entry.block_index]
        if not block.flags & FLAG_EXISTS:
            raise KeyError(f"file marked nonexistent: {name}")
        return self._read_block(name, block)

    def _read_block(self, name: str, block: _Block) -> bytes:
        raw = self._data[block.file_pos : block.file_pos + block.packed_size]
        encrypted = bool(block.flags & FLAG_ENCRYPTED)
        compressed = bool(block.flags & (FLAG_COMPRESS | FLAG_IMPLODE))

        key = 0
        if encrypted:
            base_name = name.replace("/", "\\").split("\\")[-1]
            key = _hash(base_name, HASH_FILE_KEY)
            if block.flags & FLAG_FIX_KEY:
                # block.file_pos is absolute here; the spec uses the archive-relative pos
                rel_pos = block.file_pos - self._archive_offset
                key = (key + rel_pos) ^ block.unpacked_size
                key &= 0xFFFFFFFF

        # Single-unit file: one block, optionally compressed, no sector table.
        if block.flags & FLAG_SINGLE_UNIT:
            if encrypted:
                raw = _decrypt(raw, key)
            if compressed and block.packed_size < block.unpacked_size:
                if block.flags & FLAG_IMPLODE and not (block.flags & FLAG_COMPRESS):
                    return _pkware_explode(raw)
                return _decompress(raw)
            return raw[: block.unpacked_size]

        # Sectored file.
        sector_size = self.sector_size
        num_sectors = (block.unpacked_size + sector_size - 1) // sector_size
        n_offsets = num_sectors + 1
        if block.flags & FLAG_SECTOR_CRC:
            n_offsets += 1

        offset_bytes = raw[: n_offsets * 4]
        if encrypted:
            offset_bytes = _decrypt(offset_bytes, (key - 1) & 0xFFFFFFFF)
        offsets = list(struct.unpack("<%dI" % n_offsets, offset_bytes))

        out = bytearray()
        for s in range(num_sectors):
            start, end = offsets[s], offsets[s + 1]
            chunk = raw[start:end]
            if encrypted:
                chunk = _decrypt(chunk, (key + s) & 0xFFFFFFFF)
            this_unpacked = min(sector_size, block.unpacked_size - len(out))
            if compressed and len(chunk) < this_unpacked:
                if block.flags & FLAG_IMPLODE and not (block.flags & FLAG_COMPRESS):
                    chunk = _pkware_explode(chunk)
                else:
                    chunk = _decompress(chunk)
            out += chunk
        return bytes(out[: block.unpacked_size])


def _next_pow2(n: int) -> int:
    p = 4
    while p < n:
        p <<= 1
    return p


def _build_hm3w_header(w3i: bytes) -> bytes:
    """Reconstruct the 512-byte WC3 map header (`HM3W`) for a headerless MPQ, so the World
    Editor / game recognize it as a .w3x. Map name is read best-effort from war3map.w3i."""
    name = "Archon Map"
    players = 24
    if w3i:
        try:
            ver = struct.unpack_from("<i", w3i, 0)[0]
            off = 28 if ver >= 28 else 12   # skip version/saves/editor (+game-version block if v>=28)
            end = w3i.index(b"\0", off)
            decoded = w3i[off:end].decode("latin-1", "replace").strip()
            if decoded:
                name = decoded
        except Exception:
            pass
    h = b"HM3W" + struct.pack("<I", 0) + name.encode("latin-1", "replace") + b"\0" + struct.pack("<II", 0, players)
    return h.ljust(512, b"\0")


def _store_sectored(data: bytes, sector_size: int) -> bytes:
    """Pack a file as uncompressed, sectored data (sector offset table + raw sectors)."""
    if not data:
        return b""
    n = (len(data) + sector_size - 1) // sector_size
    off = (n + 1) * 4
    offsets = [off]
    for i in range(n):
        off += len(data[i * sector_size:(i + 1) * sector_size])
        offsets.append(off)
    return struct.pack("<%dI" % (n + 1), *offsets) + data


def write_w3x(orig_path: str, overrides: dict, out_path: str, drop=("(attributes)",)):
    """Repack a .w3x: keep every file from `orig_path`, apply `overrides` (name -> bytes,
    replace or add), write to `out_path`. Files are stored uncompressed (valid, simple).
    The HM3W header is copied verbatim. `(listfile)` is rebuilt; `(attributes)` is dropped
    (optional + would carry stale CRCs)."""
    src = MPQArchive(orig_path)
    sector_size = src.sector_size
    if src._archive_offset > 0:
        header = src._data[: src._archive_offset]   # keep the existing HM3W prefix verbatim
    else:
        # headerless MPQ (e.g. W3Champions strips it) -> rebuild a 512-byte HM3W so the editor
        # and game recognize it as a .w3x; the MPQ then starts at offset 512.
        try:
            w3i = src.read_file("war3map.w3i")
        except KeyError:
            w3i = b""
        header = _build_hm3w_header(w3i)

    # gather files from the listfile, then apply overrides
    files = {}
    try:
        names = src.read_file("(listfile)").decode("latin-1").replace("\r\n", "\n").replace("\r", "\n")
        for nm in names.split("\n"):
            nm = nm.strip()
            if nm and nm not in drop:
                try:
                    files[nm] = src.read_file(nm)
                except KeyError:
                    pass
    except KeyError:
        pass
    for nm, data in overrides.items():
        files[nm] = data
    for nm in drop:
        files.pop(nm, None)
    # rebuild (listfile)
    listed = [n for n in files if n != "(listfile)"]
    files["(listfile)"] = ("\r\n".join(listed) + "\r\n").encode("latin-1")

    names = list(files.keys())
    hash_size = _next_pow2(len(names) * 2)
    sector_shift = (sector_size // 512).bit_length() - 1

    # --- lay out file data after the 32-byte MPQ header (positions are MPQ-relative) ---
    file_data = bytearray()
    block_entries = []   # (file_pos, packed, unpacked, flags)
    data_start = 32
    for nm in names:
        raw = files[nm]
        stored = _store_sectored(raw, sector_size)
        block_entries.append((data_start + len(file_data), len(stored), len(raw), FLAG_EXISTS))
        file_data += stored

    hash_off = data_start + len(file_data)
    block_off = hash_off + hash_size * 16

    # --- hash table ---
    hash_table = [[0xFFFFFFFF, 0xFFFFFFFF, 0xFFFF, 0xFFFF, HASH_ENTRY_EMPTY] for _ in range(hash_size)]
    for idx, nm in enumerate(names):
        start = _hash(nm, HASH_TABLE_OFFSET) & (hash_size - 1)
        a, b = _hash(nm, HASH_NAME_A), _hash(nm, HASH_NAME_B)
        i = start
        while hash_table[i][4] != HASH_ENTRY_EMPTY:
            i = (i + 1) & (hash_size - 1)
        hash_table[i] = [a, b, 0, 0, idx]
    hash_raw = b"".join(struct.pack("<IIHHI", *e) for e in hash_table)
    hash_raw = _encrypt(hash_raw, _hash("(hash table)", HASH_FILE_KEY))

    block_raw = b"".join(struct.pack("<IIII", *e) for e in block_entries)
    block_raw = _encrypt(block_raw, _hash("(block table)", HASH_FILE_KEY))

    archive_size = block_off + len(block_raw)
    mpq_header = struct.pack("<IIIHHIIII", MPQ_HEADER_SIG, 32, archive_size, 0,
                             sector_shift, hash_off, block_off, hash_size, len(names))

    with open(out_path, "wb") as fh:
        fh.write(header)
        fh.write(mpq_header)
        fh.write(file_data)
        fh.write(hash_raw)
        fh.write(block_raw)


if __name__ == "__main__":
    import sys
    arc = MPQArchive(sys.argv[1])
    print(f"format v{arc.format_version}, sector {arc.sector_size}, "
          f"{arc._hash_count} hash slots, {arc._block_count} blocks")
    for probe in ("war3map.j", "war3map.w3i", "(listfile)", "war3map.w3u",
                  "war3map.w3t", "war3map.w3a", "war3mapMisc.txt", "war3mapSkin.txt"):
        print(f"  {'YES' if arc.has_file(probe) else ' no'}  {probe}")
