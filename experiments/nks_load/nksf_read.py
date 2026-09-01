#!/usr/bin/env python3
"""Read a Native Instruments NKS preset (`.nksf` / `.nksfx`) container.

Spike tooling for the NKS load path (docs/PLAN_nks_load_path.md). Same status
as experiments/gmd_profiles/: development-only, standard library only, never
imported by `lib/`, never read at runtime. Its job is to make the two chunks
the spike needs — `PLID` (which plugin) and `PCHK` (the plugin's own state) —
readable without a pip dependency.

    python3 experiments/nks_load/nksf_read.py inspect <file.nksf>
    python3 experiments/nks_load/nksf_read.py --self-test

Container (measured on Massive X presets, 2026-09-01): a RIFF file whose form
type is `NIKS`, then ordinary RIFF chunks — 4-byte id, little-endian uint32
size, payload, one pad byte when the size is odd. The chunks that matter:

    NISI  msgpack map: name, bankchain, author, `modes` (Character tags),
          deviceType (`INST` / `FX`) — the retrieval metadata.
    NICA  msgpack map: NKS controller-page assignments. Not used by the spike.
    PLID  msgpack map: `VST.magic`, `VST3.uid` (four uint32 fields making up
          the VST3 class id), `pluginName`, `pluginVendor`.

The three msgpack chunks each open with a 4-byte little-endian version word
(`01 00 00 00` on every file measured here) before the map itself; `unpack`
below strips it, and refuses a version it has not seen rather than assuming
the layout survived a bump.
    PCHK  raw plugin state. NOT msgpack: the plugin's own serialization,
          opaque here and correctly so — the spike copies these bytes
          verbatim into a Live `.adv`'s `ProcessorState` buffer.

The msgpack decoder below covers exactly the subset NKS uses and raises by
name on anything else, rather than guessing at a type it has never seen.
"""
import argparse
import struct
import sys

# --- RIFF ------------------------------------------------------------------


class NksfError(Exception):
    """Anything malformed in the container or its msgpack payloads."""


def read_chunks(data):
    """Return an ordered list of (chunk_id, payload) from a RIFF/NIKS blob."""
    if len(data) < 12:
        raise NksfError("file is shorter than a RIFF header (%d bytes)" % len(data))
    magic, riff_size, form = data[0:4], struct.unpack("<I", data[4:8])[0], data[8:12]
    if magic != b"RIFF":
        raise NksfError("not a RIFF file: leading bytes are %r" % magic)
    if form != b"NIKS":
        raise NksfError("not an NKS file: RIFF form type is %r, expected b'NIKS'" % form)
    # riff_size counts everything after the size field; tolerate a file that
    # carries trailing bytes, but never read past what the header claims.
    end = min(len(data), 8 + riff_size)
    chunks = []
    off = 12
    while off + 8 <= end:
        cid = data[off:off + 4]
        size = struct.unpack("<I", data[off + 4:off + 8])[0]
        start = off + 8
        if start + size > end:
            raise NksfError(
                "chunk %r at offset %d claims %d bytes, past the end of the form"
                % (cid, off, size))
        chunks.append((cid, data[start:start + size]))
        off = start + size + (size & 1)
    return chunks


def read_file(path):
    with open(path, "rb") as f:
        return read_chunks(f.read())


# --- msgpack (the NKS subset only) -----------------------------------------


def _unpack(data, i):
    """Decode one msgpack value at offset i; return (value, next_offset)."""
    if i >= len(data):
        raise NksfError("msgpack payload ended mid-value at offset %d" % i)
    b = data[i]
    i += 1
    # fixint
    if b <= 0x7F:
        return b, i
    if b >= 0xE0:
        return b - 0x100, i
    # fixmap / fixarray / fixstr
    if 0x80 <= b <= 0x8F:
        return _unpack_map(data, i, b & 0x0F)
    if 0x90 <= b <= 0x9F:
        return _unpack_array(data, i, b & 0x0F)
    if 0xA0 <= b <= 0xBF:
        return _unpack_str(data, i, b & 0x1F)
    if b == 0xC0:
        return None, i
    if b == 0xC2:
        return False, i
    if b == 0xC3:
        return True, i
    if b == 0xC4:  # bin8
        n = data[i]
        return data[i + 1:i + 1 + n], i + 1 + n
    if b == 0xC5:  # bin16
        n = struct.unpack_from(">H", data, i)[0]
        return data[i + 2:i + 2 + n], i + 2 + n
    if b == 0xCA:  # float32
        return struct.unpack_from(">f", data, i)[0], i + 4
    if b == 0xCB:  # float64
        return struct.unpack_from(">d", data, i)[0], i + 8
    if b in (0xCC, 0xCD, 0xCE, 0xCF):  # uint 8/16/32/64
        width = 1 << (b - 0xCC)
        fmt = {1: ">B", 2: ">H", 4: ">I", 8: ">Q"}[width]
        return struct.unpack_from(fmt, data, i)[0], i + width
    if b in (0xD0, 0xD1, 0xD2, 0xD3):  # int 8/16/32/64
        width = 1 << (b - 0xD0)
        fmt = {1: ">b", 2: ">h", 4: ">i", 8: ">q"}[width]
        return struct.unpack_from(fmt, data, i)[0], i + width
    if b == 0xD9:  # str8
        return _unpack_str(data, i + 1, data[i])
    if b == 0xDA:  # str16
        return _unpack_str(data, i + 2, struct.unpack_from(">H", data, i)[0])
    if b == 0xDC:  # array16
        return _unpack_array(data, i + 2, struct.unpack_from(">H", data, i)[0])
    if b == 0xDE:  # map16
        return _unpack_map(data, i + 2, struct.unpack_from(">H", data, i)[0])
    raise NksfError(
        "unsupported msgpack type byte 0x%02X at offset %d — this decoder "
        "covers only the subset NKS uses; extend it deliberately" % (b, i - 1))


def _unpack_str(data, i, n):
    raw = data[i:i + n]
    if len(raw) != n:
        raise NksfError("msgpack string of %d bytes ran past the payload" % n)
    return raw.decode("utf-8", "replace"), i + n


def _unpack_array(data, i, n):
    out = []
    for _ in range(n):
        value, i = _unpack(data, i)
        out.append(value)
    return out, i


def _unpack_map(data, i, n):
    out = {}
    for _ in range(n):
        key, i = _unpack(data, i)
        value, i = _unpack(data, i)
        out[key] = value
    return out, i


KNOWN_CHUNK_VERSION = 1


def unpack(payload):
    """Decode a whole msgpack payload, refusing trailing garbage."""
    value, i = _unpack(payload, 0)
    if i != len(payload):
        raise NksfError("msgpack payload has %d trailing bytes" % (len(payload) - i))
    return value


def unpack_chunk(payload):
    """Decode a versioned NKS msgpack chunk (NISI / NICA / PLID)."""
    if len(payload) < 4:
        raise NksfError("chunk is too short to carry a version word")
    version = struct.unpack_from("<I", payload)[0]
    if version != KNOWN_CHUNK_VERSION:
        raise NksfError(
            "chunk version %d is not the version this reader was measured "
            "against (%d) — re-measure the layout before trusting it"
            % (version, KNOWN_CHUNK_VERSION))
    return unpack(payload[4:])


# --- plugin identity -------------------------------------------------------


def vst3_uid_fields(plid):
    """The four uint32 fields of the VST3 class id, from a decoded PLID map."""
    fields = plid.get("VST3.uid")
    if not isinstance(fields, list) or len(fields) != 4:
        raise NksfError("PLID has no 4-element 'VST3.uid': %r" % (fields,))
    return [int(f) & 0xFFFFFFFF for f in fields]


def vst3_guid(fields):
    """Dashed lowercase class id, the spelling Live's BranchDeviceId uses."""
    hexed = "".join("%08x" % f for f in fields)
    return "%s-%s-%s-%s-%s" % (hexed[0:8], hexed[8:12], hexed[12:16],
                               hexed[16:20], hexed[20:32])


# --- CLI -------------------------------------------------------------------


def cmd_inspect(path):
    chunks = read_file(path)
    print("%s" % path)
    print("chunks:")
    for cid, payload in chunks:
        print("  %-4s %8d bytes" % (cid.decode("ascii", "replace"), len(payload)))
    by_id = dict(chunks)
    for name in (b"NISI", b"PLID"):
        if name in by_id:
            print("\n%s:" % name.decode())
            try:
                decoded = unpack_chunk(by_id[name])
            except NksfError as exc:
                print("  undecodable: %s" % exc)
                continue
            for key in sorted(decoded):
                print("  %-14s %r" % (key, decoded[key]))
    if b"PLID" in by_id:
        try:
            fields = vst3_uid_fields(unpack_chunk(by_id[b"PLID"]))
            print("\nVST3 class id: %s" % vst3_guid(fields))
            print("  fields: %s" % " ".join(str(f) for f in fields))
        except NksfError as exc:
            print("\nVST3 class id: %s" % exc)
    if b"PCHK" in by_id:
        state = by_id[b"PCHK"]
        print("\nPCHK: %d bytes, first 32: %s" % (len(state), state[:32].hex().upper()))
        head = struct.unpack_from("<4I", state) if len(state) >= 16 else ()
        if head:
            print("  as 4 little-endian uint32: %s" % " ".join(str(v) for v in head))
        z = state.find(b"\x78\x9c")
        print("  zlib (78 9C) stream starts at offset: %s"
              % (z if z >= 0 else "not found"))
    return 0


def _self_test():
    """Parse a synthesized container — no NKS file, no Live, no network."""
    def chunk(cid, payload):
        pad = b"\x00" if len(payload) & 1 else b""
        return cid + struct.pack("<I", len(payload)) + payload + pad

    # msgpack map: {"pluginName": "X", "VST3.uid": [4 uint32], "n": -3,
    #               "ok": true, "none": nil}
    def mp_str(s):
        raw = s.encode()
        return bytes([0xA0 | len(raw)]) + raw if len(raw) < 32 else \
            b"\xd9" + bytes([len(raw)]) + raw

    uid_fields = [0x5653544E, 0x6924486D, 0x61737369, 0x76652078]
    body = b"\x85"  # fixmap of 5
    body += mp_str("pluginName") + mp_str("X")
    body += mp_str("VST3.uid") + b"\x94" + b"".join(
        b"\xce" + struct.pack(">I", f) for f in uid_fields)
    body += mp_str("n") + b"\xfd"          # negative fixint -3
    body += mp_str("ok") + b"\xc3"          # true
    body += mp_str("none") + b"\xc0"        # nil

    versioned = struct.pack("<I", KNOWN_CHUNK_VERSION) + body
    state = bytes(range(256)) * 3  # odd-length exercise below adds one byte
    payloads = [(b"PLID", versioned), (b"PCHK", state + b"\x01")]
    form = b"NIKS" + b"".join(chunk(cid, p) for cid, p in payloads)
    blob = b"RIFF" + struct.pack("<I", len(form)) + form

    chunks = dict(read_chunks(blob))
    assert list(dict(read_chunks(blob))) == [b"PLID", b"PCHK"], "chunk order/ids"
    assert chunks[b"PCHK"] == state + b"\x01", "odd-sized chunk padding"
    decoded = unpack_chunk(chunks[b"PLID"])
    assert decoded["pluginName"] == "X", decoded
    assert decoded["n"] == -3 and decoded["ok"] is True and decoded["none"] is None
    assert vst3_uid_fields(decoded) == uid_fields, decoded
    assert vst3_guid(uid_fields) == "5653544e-6924-486d-6173-736976652078"

    for bad, why in (
        (b"XXXX" + blob[4:], "not RIFF"),
        (blob[:8] + b"XXXX" + blob[12:], "not NIKS"),
    ):
        try:
            read_chunks(bad)
        except NksfError:
            pass
        else:
            raise AssertionError("accepted a container that is %s" % why)

    try:
        unpack(b"\xc7\x00\x00")  # ext8 — deliberately unsupported
    except NksfError as exc:
        assert "unsupported msgpack type" in str(exc), exc
    else:
        raise AssertionError("accepted an unsupported msgpack type")

    try:
        unpack(mp_str("x") + b"\x00")
    except NksfError as exc:
        assert "trailing" in str(exc), exc
    else:
        raise AssertionError("accepted trailing bytes")

    try:
        unpack_chunk(struct.pack("<I", 99) + body)
    except NksfError as exc:
        assert "version 99" in str(exc), exc
    else:
        raise AssertionError("accepted an unmeasured chunk version")

    print("self-test: ok")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--self-test", action="store_true",
                        help="parse a synthesized container and exit")
    parser.add_argument("command", nargs="?", choices=["inspect"])
    parser.add_argument("path", nargs="?")
    args = parser.parse_args(argv)
    if args.self_test:
        return _self_test()
    if args.command == "inspect" and args.path:
        return cmd_inspect(args.path)
    parser.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
