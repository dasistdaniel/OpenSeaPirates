"""
Erzeugt die kleinen Flaggen der fünf Nationen (16 × 11 Pixel, Pixelstil, selbst gezeichnet).

    python scripts/nation_flags.py priv/static/images/flags

Schreibt `<nation>.png` für spain, england, france, netherlands, portugal. Die Namen entsprechen
`Osp.Nations.all/0`. Der Client zeichnet die Bilder vor Schiffs- und Hafennamen.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw

W, H = 16, 11
OUTLINE = (20, 24, 32, 255)

RED = (200, 40, 40, 255)
WHITE = (245, 245, 240, 255)
BLUE = (40, 80, 190, 255)
YELLOW = (240, 190, 40, 255)
GREEN = (40, 140, 70, 255)


def spain(d):
    d.rectangle([0, 0, W - 1, H - 1], fill=RED)
    d.rectangle([0, 3, W - 1, 7], fill=YELLOW)


def england(d):
    d.rectangle([0, 0, W - 1, H - 1], fill=WHITE)
    d.rectangle([0, 4, W - 1, 6], fill=RED)
    d.rectangle([6, 0, 9, H - 1], fill=RED)


def france(d):
    third = W // 3
    d.rectangle([0, 0, third - 1, H - 1], fill=BLUE)
    d.rectangle([third, 0, 2 * third - 1, H - 1], fill=WHITE)
    d.rectangle([2 * third, 0, W - 1, H - 1], fill=RED)


def netherlands(d):
    d.rectangle([0, 0, W - 1, 3], fill=RED)
    d.rectangle([0, 4, W - 1, 6], fill=WHITE)
    d.rectangle([0, 7, W - 1, H - 1], fill=BLUE)


def portugal(d):
    d.rectangle([0, 0, W - 1, H - 1], fill=RED)
    d.rectangle([0, 0, 5, H - 1], fill=GREEN)
    d.ellipse([4, 3, 8, 7], fill=YELLOW)


FLAGS = {
    "spain": spain,
    "england": england,
    "france": france,
    "netherlands": netherlands,
    "portugal": portugal,
}


def main(out_dir):
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    for name, paint in FLAGS.items():
        im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        d = ImageDraw.Draw(im)
        paint(d)
        d.rectangle([0, 0, W - 1, H - 1], outline=OUTLINE)
        im.save(out / f"{name}.png")
    print(f"{len(FLAGS)} Flaggen in {out}")


if __name__ == "__main__":
    main(sys.argv[1])
