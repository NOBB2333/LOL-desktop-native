#!/usr/bin/env python3
"""把 LeagueAkari 的 ico 转成小尺寸 PNG。

ico 里的条目是 BITMAPINFOHEADER + BGRA 像素 + AND mask（不是 PNG 压缩），
所以这里手工解包再用 zlib 写 PNG——环境里装不了 Pillow。
"""
import struct
import sys
import zlib

MAX_TARGET = 128


def read_dib(data: bytes, offset: int, size: int):
    header = struct.unpack_from("<IiiHHIIiiII", data, offset)
    bi_size, width, height, planes, bit_count, compression, size_image = header[:7]
    if bi_size != 40:
        raise ValueError("unexpected DIB header size %d" % bi_size)
    if planes != 1:
        raise ValueError("unexpected planes %d" % planes)
    bit_count = bit_count or 32
    if bit_count != 32:
        raise ValueError("only 32bpp icons supported, got %d" % bit_count)
    if compression != 0:
        raise ValueError("unexpected compression %d" % compression)

    # ico 的 height 含 AND mask，是实际高度的 2 倍。
    if height % 2 != 0:
        raise ValueError("unexpected height %d" % height)
    height //= 2

    body = offset + 40
    row_bytes = ((width * bit_count + 31) // 32) * 4
    pixel_bytes = row_bytes * height
    mask_row_bytes = ((width + 31) // 32) * 4
    if size_image and size_image != pixel_bytes + mask_row_bytes * height:
        pixel_bytes = size_image

    pixels = bytearray()
    for row in range(height):
        start = body + (height - 1 - row) * row_bytes
        pixels.extend(data[start:start + width * 4])

    mask_start = body + pixel_bytes
    mask = bytearray()
    for row in range(height):
        start = mask_start + (height - 1 - row) * mask_row_bytes
        mask.extend(data[start:start + mask_row_bytes])

    return width, height, bytes(pixels), bytes(mask)


def to_rgba(width: int, height: int, pixels: bytes, mask: bytes) -> bytearray:
    mask_row_bytes = ((width + 31) // 32) * 4
    out = bytearray()
    for y in range(height):
        out.append(0)  # PNG filter: None
        for x in range(width):
            base = (y * width + x) * 4
            b, g, r, a = pixels[base:base + 4]
            if a == 0:
                # 没有 alpha 通道信息时退回 AND mask：1 = 透明。
                bit = mask[y * mask_row_bytes + (x >> 3)] >> (7 - (x & 7)) & 1
                a = 0 if bit else 255
            out.extend((r, g, b, a))
    return out


def write_png(path: str, width: int, height: int, raw: bytearray) -> None:
    def chunk(tag: bytes, payload: bytes) -> bytes:
        return struct.pack(">I", len(payload)) + tag + payload + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as handle:
        handle.write(png)


def best_entry(data: bytes) -> tuple[int, int]:
    count = struct.unpack_from("<H", data, 4)[0]
    entries = []
    for index in range(count):
        offset = 6 + index * 16
        w, h, _cc, _r, _pl, bc, size, image_offset = struct.unpack_from("<BBBBHHII", data, offset)
        entries.append((w or 256, h or 256, bc, size, image_offset))
    # 挑一个不超过目标、但尽量大的条目。
    usable = [e for e in entries if e[0] <= MAX_TARGET] or entries
    usable.sort(key=lambda e: e[0])
    return usable[-1][0], usable[-1][4]


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: ico_to_png.py <input.ico> <output.png>")
        return 1
    data = open(sys.argv[1], "rb").read()
    width, offset = best_entry(data)
    w, h, pixels, mask = read_dib(data, offset, None)
    write_png(sys.argv[2], w, h, to_rgba(w, h, pixels, mask))
    print("%s -> %s (%dx%d)" % (sys.argv[1], sys.argv[2], w, h))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
