#!/usr/bin/python3
"""Is a file found by content whole? A look at its structure, not its content.

PhotoRec rebuilds files from their first bytes and its idea of where they end:
a photo can lose its second half, a video its index, an archive its directory,
and still show a thumbnail. Each file is read only where its format says what
a whole file looks like: the start, the end, the chain of chunks or boxes.

  complete    the structure is whole (it does not prove every byte is right)
  truncated   it ends before its format says it does
  damaged     its structure is broken (a bad chunk, a missing index)
  unknown     a format this does not check, or one too large to walk

Every file is untrusted: nothing is decoded or run, reads are bounded, and a
length read from a file is never trusted to allocate memory.

Usage: python3 -I integrity.py ROOT < INDEX > RESULTS
INDEX: the records of a search (size<TAB>mtime<TAB>category<TAB>path<NUL>),
paths relative to ROOT. RESULTS: status<TAB>path<NUL> for each, in order, and
on stderr one line of counts, "complete N truncated N damaged N unknown N".
"""

import os
import struct
import sys
import zlib

TAIL = 65536 + 22
# A PNG is walked chunk by chunk, CRC included, up to this much
PNG_WALK_MAX = 256 * 1024 * 1024
BOXES_MAX = 100000


def _tail(f, size, n=TAIL):
    f.seek(max(0, size - n))
    return f.read(n)


def check_jpeg(f, size):
    f.seek(0)
    if f.read(3) != b"\xff\xd8\xff":
        return "damaged"
    # The segments before the image data must chain up
    pos = 2
    while True:
        f.seek(pos)
        head = f.read(4)
        if len(head) < 4:
            return "truncated"
        if head[0] != 0xFF:
            return "damaged"
        marker = head[1]
        if marker == 0xDA:  # start of scan: image data follows
            break
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            pos += 2
            continue
        length = struct.unpack(">H", head[2:4])[0]
        if length < 2:
            return "damaged"
        pos += 2 + length
        if pos > size:
            return "truncated"
    end = _tail(f, size, 4096).rstrip(b"\x00")
    return "complete" if end.endswith(b"\xff\xd9") else "truncated"


def check_png(f, size):
    f.seek(0)
    if f.read(8) != b"\x89PNG\r\n\x1a\n":
        return "damaged"
    if size > PNG_WALK_MAX:
        return "unknown"
    pos, seen = 8, set()
    while True:
        f.seek(pos)
        head = f.read(8)
        if len(head) < 8:
            return "truncated"
        length, kind = struct.unpack(">I4s", head)
        # A chunk name is four letters, and a length never above 2^31 - 1:
        # anything else is not a chunk
        if not kind.isalpha() or length > 0x7FFFFFFF:
            return "damaged"
        # IHDR comes first, and the image data before the end
        if (pos == 8) != (kind == b"IHDR"):
            return "damaged"
        if pos + 12 + length > size:
            return "truncated"
        # The CRC is computed in pieces: a length read from the file never
        # decides how much memory is taken
        crc, left = zlib.crc32(kind), length
        while left:
            piece = f.read(min(left, 1 << 20))
            if not piece:
                return "truncated"
            crc, left = zlib.crc32(piece, crc), left - len(piece)
        stored = f.read(4)
        if len(stored) < 4:
            return "truncated"
        if crc != struct.unpack(">I", stored)[0]:
            return "damaged"
        if kind == b"IEND":
            return "complete" if b"IDAT" in seen else "damaged"
        seen.add(kind)
        pos += 12 + length


def check_gif(f, size):
    f.seek(0)
    if f.read(6) not in (b"GIF87a", b"GIF89a"):
        return "damaged"
    return "complete" if _tail(f, size, 4096).rstrip(b"\x00").endswith(b";") else "truncated"


def check_pdf(f, size):
    f.seek(0)
    if not f.read(1024).lstrip().startswith(b"%PDF-"):
        return "damaged"
    end = _tail(f, size, 2048).rstrip(b"\x00\r\n\t ")
    return "complete" if end.endswith(b"%%EOF") else "truncated"


def check_zip(f, size):
    """zip, and what is a zip inside: docx, xlsx, pptx, odt, epub, jar, apk."""
    f.seek(0)
    if f.read(4) != b"PK\x03\x04":
        return "damaged"
    tail = _tail(f, size)
    at = tail.rfind(b"PK\x05\x06")
    if at < 0 or len(tail) - at < 22:
        return "truncated"
    cd_size, cd_offset = struct.unpack("<II", tail[at + 12:at + 20])
    start = size - len(tail) + at
    if 0xFFFFFFFF in (cd_size, cd_offset):
        # zip64: the directory is described by a record that a locator, just
        # before the end record, points to
        loc = tail[at - 20:at] if at >= 20 else b""
        if len(loc) < 20 or loc[:4] != b"PK\x06\x07":
            return "damaged"
        start = struct.unpack("<Q", loc[8:16])[0]
        if start + 56 > size - 20 - (len(tail) - at):
            return "damaged"
        f.seek(start)
        record = f.read(56)
        if len(record) < 56 or record[:4] != b"PK\x06\x06":
            return "damaged"
        cd_size, cd_offset = struct.unpack("<QQ", record[40:56])
    return "complete" if cd_offset + cd_size <= start else "damaged"


def check_isobmff(f, size):
    """mp4, mov, m4a, 3gp, heic: a chain of boxes that must cover the file,
    with the index (moov) somewhere in it."""
    pos, count, seen = 0, 0, set()
    while pos < size:
        f.seek(pos)
        head = f.read(8)
        if len(head) < 8:
            return "truncated"
        box, kind = struct.unpack(">I4s", head)
        if box == 1:
            ext = f.read(8)
            if len(ext) < 8:
                return "truncated"
            box = struct.unpack(">Q", ext)[0]
        elif box == 0:
            box = size - pos
        if box < 8:
            return "damaged"
        seen.add(kind)
        if pos + box > size:
            return "truncated"
        pos += box
        count += 1
        if count > BOXES_MAX:
            return "unknown"
    if b"ftyp" not in seen:
        return "damaged"
    if b"moov" not in seen and b"meta" not in seen:
        return "damaged"
    return "complete"


def check_riff(f, size):
    """wav, avi, webp: RIFF says how long it is."""
    f.seek(0)
    head = f.read(12)
    if len(head) < 12 or head[:4] != b"RIFF":
        return "damaged"
    want = struct.unpack("<I", head[4:8])[0] + 8
    return "complete" if size >= want else "truncated"


def check_bmp(f, size):
    f.seek(0)
    head = f.read(6)
    if len(head) < 6 or head[:2] != b"BM":
        return "damaged"
    return "complete" if size >= struct.unpack("<I", head[2:6])[0] else "truncated"


def check_sqlite(f, size):
    f.seek(0)
    head = f.read(32)
    if len(head) < 32 or not head.startswith(b"SQLite format 3\x00"):
        return "damaged"
    page = struct.unpack(">H", head[16:18])[0]
    page = 65536 if page == 1 else page
    pages = struct.unpack(">I", head[28:32])[0]
    if not pages:
        return "unknown"
    return "complete" if size >= page * pages else "truncated"


CHECKS = {
    "jpg": check_jpeg, "jpeg": check_jpeg, "png": check_png, "gif": check_gif, "pdf": check_pdf,
    "zip": check_zip, "docx": check_zip, "xlsx": check_zip, "pptx": check_zip, "odt": check_zip, "ods": check_zip,
    "odp": check_zip, "epub": check_zip, "jar": check_zip, "apk": check_zip, "sxw": check_zip,
    "mp4": check_isobmff, "mov": check_isobmff, "m4a": check_isobmff, "m4v": check_isobmff, "3gp": check_isobmff,
    "heic": check_isobmff, "wav": check_riff, "avi": check_riff, "webp": check_riff, "bmp": check_bmp,
    "sqlite": check_sqlite, "db": check_sqlite,
}


def check(path):
    ext = path.rsplit(".", 1)[-1].lower() if "." in os.path.basename(path) else ""
    fn = CHECKS.get(ext)
    if fn is None:
        return "unknown"
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as f:
            st = os.fstat(f.fileno())
            if not (st.st_mode & 0o170000 == 0o100000) or st.st_size == 0:
                return "damaged" if st.st_size == 0 else "unknown"
            return fn(f, st.st_size)
    except (OSError, struct.error, ValueError, OverflowError):
        return "unknown"


def main():
    root = os.fsencode(sys.argv[1])
    counts = dict.fromkeys(("complete", "truncated", "damaged", "unknown"), 0)
    out = sys.stdout.buffer
    for record in sys.stdin.buffer.read().split(b"\0"):
        if not record:
            continue
        parts = record.split(b"\t", 3)
        # One answer per record, in order: the window matches them by position
        if len(parts) != 4 or parts[3].startswith(b"/") or b"/../" in b"/" + parts[3] + b"/":
            status, parts = "unknown", [b""] * 3 + [parts[-1]]
        else:
            status = check(os.fsdecode(os.path.join(root, parts[3])))
        counts[status] += 1
        out.write(status.encode() + b"\t" + parts[3] + b"\0")
    print(" ".join(f"{k} {v}" for k, v in counts.items()), file=sys.stderr)


if __name__ == "__main__":
    main()
