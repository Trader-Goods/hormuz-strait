#!/usr/bin/env python3
"""Composite real simulator screenshots onto App Store marketing frames."""

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

CAPTIONS = [
    ("home", "Get yard work done fast", "01-get-yard-work-done-fast"),
    ("map", "Pros near you", "02-pros-near-you"),
    ("post", "Set your price", "03-set-your-price"),
    ("pay", "Pay safely when it's done", "04-pay-safely-when-its-done"),
    ("welcome", "Simple for everyone", "05-simple-for-everyone"),
]

SIZES = {
    "6.7": (1290, 2796),
    "6.5": (1284, 2778),
}

TOP = (60, 203, 127)
BOTTOM = (16, 92, 52)


def font(size: int) -> ImageFont.ImageFont:
    candidates = [
        "/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/Library/Fonts/Arial Bold.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    ]
    for path in candidates:
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def gradient(size: tuple[int, int]) -> Image.Image:
    width, height = size
    image = Image.new("RGB", size)
    pixels = image.load()
    for y in range(height):
        blend = y / max(height - 1, 1)
        color = tuple(int(TOP[i] + (BOTTOM[i] - TOP[i]) * blend) for i in range(3))
        for x in range(width):
            pixels[x, y] = color
    return image


def wrap(draw: ImageDraw.ImageDraw, text: str, face: ImageFont.ImageFont, width: int) -> list[str]:
    words = text.split()
    lines: list[str] = []
    current = ""
    for word in words:
        trial = word if not current else f"{current} {word}"
        if draw.textlength(trial, font=face) <= width:
            current = trial
        else:
            if current:
                lines.append(current)
            current = word
    if current:
        lines.append(current)
    return lines


def rounded(shot: Image.Image, radius: int) -> Image.Image:
    mask = Image.new("L", shot.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, shot.width, shot.height), radius=radius, fill=255)
    out = shot.convert("RGBA")
    out.putalpha(mask)
    return out


BACKGROUNDS = {
    "home": "yard-mow",
    "map": "yard-hedge",
    "post": "yard-mulch",
    "pay": "yard-pro",
    "welcome": "yard-leaves",
}


def cover(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    width, height = size
    scale = max(width / image.width, height / image.height)
    resized = image.resize((int(image.width * scale), int(image.height * scale)), Image.Resampling.LANCZOS)
    left = max(0, (resized.width - width) // 2)
    top = max(0, (resized.height - height) // 5)
    return resized.crop((left, top, left + width, top + height))


def photo_background(name: str, size: tuple[int, int]) -> Image.Image:
    path = Path("Contractor/Assets.xcassets") / f"{name}.imageset" / f"{name}@3x.jpg"
    if not path.exists():
        path = Path(__file__).resolve().parents[1] / path
    photo = cover(Image.open(path).convert("RGB"), size)
    shade = Image.new("RGB", size, (6, 16, 12))
    return Image.blend(photo, shade, 0.42)


def compose(raw: Path, caption: str, size: tuple[int, int], background: str) -> Image.Image:
    width, height = size
    canvas = photo_background(background, size).convert("RGBA")
    draw = ImageDraw.Draw(canvas)
    margin = int(width * 0.08)
    text_width = width - margin * 2
    face = font(int(width * 0.072))
    lines = wrap(draw, caption, face, text_width)
    while len(lines) > 3 and getattr(face, "size", 40) > 48:
        face = font(face.size - 4)
        lines = wrap(draw, caption, face, text_width)
    line_h = int(getattr(face, "size", 72) * 1.12)
    y = int(height * 0.055)
    for line in lines:
        draw.text((width / 2, y), line, font=face, fill=(255, 255, 255), anchor="ma")
        y += line_h

    shot = Image.open(raw).convert("RGBA")
    bezel = int(width * 0.012)
    phone_w = int(width * 0.72)
    scale = phone_w / shot.width
    shot = shot.resize((phone_w, max(1, int(shot.height * scale))), Image.Resampling.LANCZOS)
    top = y + int(height * 0.035)
    max_h = height - top - int(height * 0.045)
    if shot.height > max_h:
        shot = shot.crop((0, 0, shot.width, max_h))
    radius = int(width * 0.055)
    inner = rounded(shot, radius)
    frame_w = shot.width + bezel * 2
    frame_h = shot.height + bezel * 2
    left = (width - frame_w) // 2
    frame = Image.new("RGBA", (frame_w, frame_h), (0, 0, 0, 0))
    ImageDraw.Draw(frame).rounded_rectangle((0, 0, frame_w - 1, frame_h - 1), radius=radius + bezel, fill=(12, 14, 13, 255))
    frame.paste(inner, (bezel, bezel), inner)
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (left + 10, top + 18, left + frame_w + 10, top + frame_h + 18),
        radius=radius + bezel,
        fill=(0, 0, 0, 90),
    )
    canvas = Image.alpha_composite(canvas, shadow)
    canvas.paste(frame, (left, top), frame)
    return canvas.convert("RGB")


def main() -> None:
    raw_dir = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    made = 0
    for size_name, pixels in SIZES.items():
        folder = out_dir / size_name
        folder.mkdir(parents=True, exist_ok=True)
        for shot, caption, slug in CAPTIONS:
            source = raw_dir / f"{size_name}-{shot}.png"
            if not source.exists() and size_name == "6.5":
                source = raw_dir / f"6.7-{shot}.png"
            if not source.exists():
                print(f"missing {size_name}-{shot}", file=sys.stderr)
                continue
            frame = compose(source, caption, pixels, BACKGROUNDS[shot])
            dest = folder / f"{slug}.png"
            frame.save(dest, "PNG")
            print(f"wrote {dest} {frame.size}")
            made += 1
    if made < 5:
        sys.exit(1)


if __name__ == "__main__":
    main()
