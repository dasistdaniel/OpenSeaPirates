"""
Erzeugt das Vorschaubild für geteilte Links (WhatsApp, Discord, ...): 1200 × 630 Pixel.

    python scripts/preview_image.py priv/static/images/preview.jpg

Meer mit Wellen, vier Schiffe aus `priv/static/images/ships` und der Titel. Nur Pillow.
"""
import math
import random
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageFilter

W, H = 1200, 630
SHIPS = Path(__file__).resolve().parent.parent / "priv" / "static" / "images" / "ships"
FONT_BOLD = "C:/Windows/Fonts/segoeuib.ttf"
FONT_REG = "C:/Windows/Fonts/segoeui.ttf"


def font(path, size):
    try:
        return ImageFont.truetype(path, size)
    except OSError:
        return ImageFont.load_default()


def sea():
    img = Image.new("RGB", (W, H))
    px = img.load()
    for y in range(H):
        for x in range(W):
            t = (x * 0.35 + y) / (W * 0.35 + H)
            px[x, y] = (int(8 + 14 * t), int(48 + 42 * t), int(86 + 54 * t))
    d = ImageDraw.Draw(img, "RGBA")
    rnd = random.Random(7)
    for _ in range(210):
        x, y, w = rnd.randint(0, W), rnd.randint(0, H), rnd.randint(18, 54)
        d.arc([x - w, y - 8, x + w, y + 8], 200, 340, fill=(255, 255, 255, rnd.randint(25, 70)), width=2)
    return img


def ship(name, scale, angle):
    im = Image.open(SHIPS / f"{name}.png").convert("RGBA")
    im = im.resize((round(im.width * scale), round(im.height * scale)), Image.LANCZOS)
    return im.rotate(angle, expand=True, resample=Image.BICUBIC)


def wake(img, x, y, angle, length):
    d = ImageDraw.Draw(img, "RGBA")
    a = math.radians(angle)
    for k in range(1, 12):
        cx, cy = x - math.sin(a) * k * length / 11, y - math.cos(a) * k * length / 11
        r = 6 + k * 2.2
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=(255, 255, 255, max(10, 90 - k * 7)), width=2)


def main(out):
    img = sea()
    # Schiffe von rechts unten nach links oben; die Bilder zeigen mit dem Bug nach unten
    fleet = [
        ("galeone_red", 2.5, 135, 940, 330),
        ("fregatte_black", 2.1, 160, 700, 470),
        ("brigg_blue", 1.9, 120, 1060, 540),
        ("schaluppe_yellow", 1.9, 150, 830, 190),
    ]
    for name, scale, angle, x, y in fleet:
        wake(img, x, y, angle - 180, 150)
    for name, scale, angle, x, y in fleet:
        s = ship(name, scale, angle - 180)
        img.alpha_composite(s, (x - s.width // 2, y - s.height // 2)) if img.mode == "RGBA" else img.paste(
            s, (x - s.width // 2, y - s.height // 2), s
        )

    # Verlauf links dunkler, damit der Text lesbar bleibt
    shade = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shade)
    for x in range(W):
        alpha = int(max(0, 190 * (1 - x / 760)))
        sd.line([(x, 0), (x, H)], fill=(4, 14, 26, alpha))
    img = Image.alpha_composite(img.convert("RGBA"), shade)

    d = ImageDraw.Draw(img)
    d.text((70, 150), "OFFENE SEE", font=font(FONT_BOLD, 28), fill=(251, 191, 36))
    for i, line in enumerate(["Open Sea", "Pirates"]):
        d.text((68, 195 + i * 118), line, font=font(FONT_BOLD, 108), fill=(3, 10, 18))
        d.text((64, 190 + i * 118), line, font=font(FONT_BOLD, 108), fill=(255, 248, 230))
    sub = font(FONT_REG, 34)
    d.text((70, 450), "Segle durch die unendliche Welt,", font=sub, fill=(226, 232, 240))
    d.text((70, 494), "finde Gefechte, werde reich.", font=sub, fill=(226, 232, 240))
    d.text((70, 560), "Kostenlos im Browser · für kleine Gruppen", font=font(FONT_REG, 26), fill=(148, 163, 184))

    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    img.convert("RGB").save(out, quality=88, optimize=True)
    print(f"{out} ({out.stat().st_size // 1024} kB)")


if __name__ == "__main__":
    main(sys.argv[1])
