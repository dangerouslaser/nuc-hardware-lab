"""Check / corrupt the Dolby Vision Standard tunnel metadata in a 3840x2160
XRGB8888 (B,G,R,X bytes) frame. Logic from yblod-engine/tools/accuracy/dvtunnel.py.

  tunnelcheck.py check FRAME            -> valid packet count, first bytes
  tunnelcheck.py corrupt IN OUT         -> flip one metadata bit per packet
"""
import sys
import numpy as np

W, H = 3840, 2160
PK = 3072  # pixels per 128-byte packet (1024 bits + repeat)


def crc32_mpeg2(data):
    crc = 0xFFFFFFFF
    for b in data:
        crc ^= b << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if crc & 0x80000000 else (crc << 1) & 0xFFFFFFFF
    return crc


def load(path):
    a = np.fromfile(path, dtype=np.uint8).reshape(H, W, 4)
    b, g, r = a[..., 0].astype(np.int32), a[..., 1].astype(np.int32), a[..., 2].astype(np.int32)
    y = (g << 4) | (b & 15)
    c = (r << 4) | (b >> 4)
    return a, y.reshape(-1), c.reshape(-1)


def packet(y, c, pk):
    idx = np.arange(pk * PK, pk * PK + 1024)
    cc, yy = c[idx], y[idx]
    pc = np.array([bin(int(v) >> 1).count("1") for v in cc])
    py = np.array([bin(int(v)).count("1") for v in yy])
    bits = (cc & 1) ^ ((pc + py) & 1)
    by = np.packbits(bits.astype(np.uint8)).tobytes()
    return by, crc32_mpeg2(by[:124]) == int.from_bytes(by[124:], "big")


def check(path, maxpk=16):
    _, y, c = load(path)
    good, first = 0, None
    for pk in range(maxpk):
        by, ok = packet(y, c, pk)
        if pk == 0:
            first = by[:16].hex()
        if not ok:
            break
        good += 1
    return good, first


if __name__ == "__main__":
    if sys.argv[1] == "check":
        good, first = check(sys.argv[2])
        print(f"{sys.argv[2]}: {good} leading packets with valid CRC; packet0 {first}")
        sys.exit(0 if good else 1)
    if sys.argv[1] == "corrupt":
        a, y, c = load(sys.argv[2])
        flat = a.reshape(-1, 4)
        good, _ = check(sys.argv[2])
        # Flip chroma LSB (bit 4 of B) of the 8th pixel of every packet: one
        # metadata bit per packet, one 12-bit chroma code. The picture is
        # unchanged to the eye; every CRC fails.
        for pk in range(max(good, 1) + 2):
            flat[pk * PK + 7, 0] ^= 0x10
        flat.tofile(sys.argv[3])
        g2, _ = check(sys.argv[3])
        print(f"corrupted {sys.argv[3]}: {g2} valid packets (was {good})")
        sys.exit(0 if g2 == 0 else 1)
