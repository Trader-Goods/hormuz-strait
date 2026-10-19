#!/usr/bin/env python3
"""Draw the Hormuz Strait app icon and splash. Output is opaque RGB."""

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
ICON = ROOT / "assets" / "icon.png"
SPLASH = ROOT / "assets" / "splash.png"
APPICON = ROOT / "ios" / "App" / "App" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon-512@2x.png"
SPLASH_SET = ROOT / "ios" / "App" / "App" / "Assets.xcassets" / "Splash.imageset"
FONT = Path("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf")

NAVY = (7, 26, 43)
DEEP = (6, 18, 32)
HORIZON = (18, 72, 112)
WATER = (10, 44, 72)
HULL_TOP = (42, 61, 85)
HULL_BOT = (14, 23, 36)
BOOT = (163, 48, 31)
BOOT_DARK = (110, 26, 17)
WHITE = (245, 246, 248)
GOLD = (255, 226, 138)
FUNNEL = (192, 57, 43)
WINDOW = (127, 196, 238)
WINDOW_DARK = (36, 56, 77)
DECK = (92, 104, 117)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient(size):
    w, h = size
    img = Image.new("RGB", size, NAVY)
    draw = ImageDraw.Draw(img)
    horizon = int(h * 0.30)
    for y in range(h):
        if y < horizon:
            t = y / max(1, horizon)
            color = lerp(DEEP, HORIZON, t * 0.55)
        else:
            t = (y - horizon) / max(1, h - horizon)
            color = lerp(WATER, DEEP, t ** 0.85)
        draw.line([(0, y), (w, y)], fill=color)
    return img


def to_canvas(gx, gy, origin, scale):
    # Game coordinates already use canvas orientation: positive y is down.
    return (origin[0] + gx * scale, origin[1] + gy * scale)


def draw_waves(draw, size, origin, scale):
    w, _h = size
    waterline = to_canvas(0, 5.2, origin, scale)[1]
    for i, amp in enumerate((0.28, 0.18, 0.12)):
        y0 = waterline + scale * (1.1 + i * 1.35)
        color = (210, 228, 236) if i == 0 else (90, 150, 180)
        pts = []
        step = max(4, int(w / 180))
        for x in range(0, w + step, step):
            y = y0 + math.sin((x / scale) * 0.45 + i) * scale * amp
            pts.append((x, y))
        draw.line(pts, fill=color, width=max(2, int(scale * 0.16)))


def paint_clipped(img, polygon, color, y0, y1):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).polygon(polygon, fill=255)
    band = Image.new("L", img.size, 0)
    ImageDraw.Draw(band).rectangle([0, min(y0, y1), img.size[0], max(y0, y1)], fill=255)
    clipped = Image.frombytes("L", img.size, bytes(a & b for a, b in zip(mask.tobytes(), band.tobytes())))
    layer = Image.new("RGB", img.size, color)
    img.paste(layer, (0, 0), clipped)


def draw_tanker(img, origin, scale):
    def gp(gx, gy):
        return to_canvas(gx, gy, origin, scale)

    # Side view, bow to the right: dark upper hull, red boot topping.
    hull = [
        gp(-24, -5.5), gp(16, -6.5), gp(24, -4), gp(27, -1),
        gp(25, 3), gp(22, 8), gp(-21, 8), gp(-24, 4),
    ]
    draw = ImageDraw.Draw(img)
    draw.polygon(hull, fill=HULL_TOP)
    paint_clipped(img, hull, BOOT, gp(0, 2.2)[1], img.size[1])
    paint_clipped(img, hull, BOOT_DARK, gp(0, 5.4)[1], img.size[1])
    paint_clipped(img, hull, WHITE, gp(0, 1.5)[1], gp(0, 2.6)[1])
    draw = ImageDraw.Draw(img)
    draw.line(hull + [hull[0]], fill=(5, 9, 15), width=max(3, int(scale * 0.14)))

    def box(a, b, **kwargs):
        draw.rectangle([min(a[0], b[0]), min(a[1], b[1]), max(a[0], b[0]), max(a[1], b[1])], **kwargs)

    draw.polygon([gp(-22.5, -5.5), gp(-22.5, -16), gp(-10, -16), gp(-9, -5.5)], fill=WHITE, outline=(5, 9, 15))
    for row, color in ((0, WINDOW), (1, WINDOW_DARK)):
        for i in range(4):
            box(gp(-21 + i * 2.8, -14.2 + row * 3.6), gp(-19.4 + i * 2.8, -12.6 + row * 3.6), fill=color)
    draw.polygon([gp(-24, -16.6), gp(-8.2, -16.6), gp(-8.2, -15.2), gp(-24, -15.2)], fill=(244, 246, 248), outline=(5, 9, 15))
    draw.polygon([gp(-18.2, -16.4), gp(-17.6, -20.2), gp(-13.4, -20.2), gp(-13.8, -16.4)], fill=(29, 42, 56), outline=(5, 9, 15))
    box(gp(-17.4, -19.4), gp(-13.8, -18.2), fill=FUNNEL)
    box(gp(-17.6, -18.6), gp(-13.6, -18.0), fill=WHITE)
    draw.line([gp(-8, -8.6), gp(20, -9.6)], fill=GOLD, width=max(3, int(scale * 0.18)))
    draw.line([gp(-8, -7.2), gp(22, -7.6)], fill=DECK, width=max(4, int(scale * 0.24)))
    for i in range(4):
        box(gp(-4 + i * 5.2, -8.8), gp(-1.2 + i * 5.2, -7.2), fill=(201, 162, 39), outline=(90, 70, 16))
    draw.polygon([gp(8, -7.4), gp(8, -11.2), gp(13.5, -11.2), gp(13.5, -7.4)], fill=(211, 84, 0), outline=(5, 9, 15))


def draw_title(img, text, y, size, fill=GOLD):
    draw = ImageDraw.Draw(img)
    font = ImageFont.truetype(str(FONT), size)
    bbox = draw.textbbox((0, 0), text, font=font)
    width = bbox[2] - bbox[0]
    x = (img.size[0] - width) / 2 - bbox[0]
    stroke = max(2, size // 18)
    draw.text((x, y), text, font=font, fill=fill, stroke_width=stroke, stroke_fill=(11, 29, 46))


def render(size, title, subtitle=None):
    w, h = size
    img = gradient(size)
    scale = w / 58
    origin = (w * 0.50 - scale * 1.0, h * 0.46)
    draw_waves(ImageDraw.Draw(img), size, origin, scale)
    draw_tanker(img, origin, scale)
    draw_title(img, title, int(h * 0.72), int(w * 0.092))
    if subtitle:
        draw_title(img, subtitle, int(h * 0.80), int(w * 0.045), fill=(207, 227, 241))
    return img


def assert_rgb(path, size):
    data = path.read_bytes()
    if data[12:16] != b"IHDR":
        raise SystemExit(f"{path} is not a PNG")
    color_type = data[25]
    if color_type != 2:
        raise SystemExit(f"{path} color type {color_type} is not opaque RGB")
    with Image.open(path) as im:
        if im.mode != "RGB" or im.size != size:
            raise SystemExit(f"{path} is {im.mode} {im.size}, expected RGB {size}")


def main():
    if not FONT.exists():
        raise SystemExit(f"missing font {FONT}")
    ICON.parent.mkdir(parents=True, exist_ok=True)
    icon = render((1024, 1024), "HORMUZ")
    splash = render((2732, 2732), "HORMUZ", "STRAIT")
    icon.save(ICON, format="PNG")
    icon.save(APPICON, format="PNG")
    splash.save(SPLASH, format="PNG")
    for name in ("splash-2732x2732.png", "splash-2732x2732-1.png", "splash-2732x2732-2.png"):
        splash.save(SPLASH_SET / name, format="PNG")
    assert_rgb(ICON, (1024, 1024))
    assert_rgb(APPICON, (1024, 1024))
    assert_rgb(SPLASH, (2732, 2732))
    print(ICON)
    print(APPICON)
    print(SPLASH)


if __name__ == "__main__":
    main()
