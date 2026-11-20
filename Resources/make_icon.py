#!/usr/bin/env python3
"""Generates Pulse.icns (no macOS tools needed). ICNS = header + PNG-embedded entries."""
import math, struct, io, os
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))

def render(size):
    S = size * 4  # supersample
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    m = int(S * 0.08); r = int(S * 0.22)
    # background gradient (deep indigo -> near-black)
    grad = Image.new("RGBA", (S, S))
    gd = ImageDraw.Draw(grad)
    for y in range(S):
        t = y / S
        c = (int(28 + (10 - 28) * t), int(22 + (8 - 22) * t), int(48 + (16 - 48) * t), 255)
        gd.line([(0, y), (S, y)], fill=c)
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([m, m, S - m, S - m], radius=r, fill=255)
    img.paste(grad, (0, 0), mask)

    # glow blob
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gg = ImageDraw.Draw(glow)
    gg.ellipse([S*0.15, S*0.1, S*0.85, S*0.8], fill=(120, 80, 255, 110))
    glow = glow.filter(ImageFilter.GaussianBlur(S * 0.12))
    img.alpha_composite(Image.composite(glow, Image.new("RGBA", (S, S), (0,0,0,0)), mask))

    # ring arcs: violet->cyan (GPU) and coral->amber (memory)
    cx, cy = S / 2, S / 2
    R = S * 0.30; w = int(S * 0.055)
    box = [cx - R, cy - R, cx + R, cy + R]
    track = Image.new("RGBA", (S, S), (0,0,0,0)); td = ImageDraw.Draw(track)
    td.arc(box, 0, 360, fill=(255, 255, 255, 28), width=w)
    steps = 120
    for i in range(steps):  # violet -> cyan, from -90 to 150 deg
        t = i / steps
        a0 = -90 + 240 * t; a1 = a0 + 240 / steps + 1
        c = (int(140 + (64 - 140) * t), int(92 + (217 - 92) * t), int(255 + (255 - 255) * t), 255)
        d.arc(box, a0, a1, fill=c, width=w)
    # small inner memory arc
    R2 = S * 0.20; w2 = int(S * 0.045)
    box2 = [cx - R2, cy - R2, cx + R2, cy + R2]
    td.arc(box2, 0, 360, fill=(255, 255, 255, 22), width=w2)
    img.alpha_composite(track)
    for i in range(steps):
        t = i / steps
        a0 = -90 + 170 * t; a1 = a0 + 170 / steps + 1
        c = (255, int(115 + (200 - 115) * t), int(102 + (77 - 102) * t), 255)
        d.arc(box2, a0, a1, fill=c, width=w2)

    # pulse waveform in the center
    pts = []
    xs = [0.36, 0.42, 0.46, 0.50, 0.54, 0.58, 0.64]
    ys = [0.50, 0.50, 0.40, 0.62, 0.44, 0.50, 0.50]
    for x, y in zip(xs, ys):
        pts.append((x * S, y * S))
    d.line(pts, fill=(255, 255, 255, 240), width=int(S * 0.028), joint="curve")

    return img.resize((size, size), Image.LANCZOS)

# PNG-in-ICNS entries. The small sizes use the retina slots (ic11 = 16@2x, ic12 = 32@2x): the old
# icp4/icp5 slots holding PNG data draw as garbage in System Settings on current macOS.
TYPES = [(b"ic11", 32), (b"ic12", 64), (b"ic07", 128), (b"ic13", 256), (b"ic08", 256),
         (b"ic14", 512), (b"ic09", 512), (b"ic10", 1024)]
ICONSET = {"icon_16x16": 16, "icon_16x16@2x": 32, "icon_32x32": 32, "icon_32x32@2x": 64,
           "icon_128x128": 128, "icon_128x128@2x": 256, "icon_256x256": 256, "icon_256x256@2x": 512,
           "icon_512x512": 512, "icon_512x512@2x": 1024}

def main():
    cache = {}
    def png(size):
        if size not in cache:
            buf = io.BytesIO(); render(size).save(buf, "PNG"); cache[size] = buf.getvalue()
        return cache[size]
    entries = b""
    for tag, size in TYPES:
        data = png(size)
        entries += tag + struct.pack(">I", len(data) + 8) + data
    icns = b"icns" + struct.pack(">I", len(entries) + 8) + entries
    out = os.path.join(HERE, "Pulse.icns")
    with open(out, "wb") as f: f.write(icns)
    # build.sh prefers this folder and runs Apple's iconutil on it, which is the authoritative path.
    iconset = os.path.join(HERE, "Pulse.iconset")
    os.makedirs(iconset, exist_ok=True)
    for name, size in ICONSET.items():
        with open(os.path.join(iconset, name + ".png"), "wb") as f: f.write(png(size))
    render(512).save(os.path.join(HERE, "icon_preview.png"))
    print("wrote", out, len(icns), "bytes and", iconset)

if __name__ == "__main__":
    main()
