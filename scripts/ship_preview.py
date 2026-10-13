"""
Probeblatt: Schiffsklassen aus den Einzelteilen des Kenney Pirate Pack zusammengesetzt.

    python scripts/ship_preview.py <pfad/zur/pirate-pack.zip> <ausgabe.png>

Bug zeigt nach unten (wie die fertigen Schiffe des Packs), Teile werden von hinten nach vorn gelegt:
Rumpf, Kanonen, Segel, Krähennest, Flagge.
"""
import io
import sys
import zipfile

from PIL import Image, ImageDraw, ImageFont

PARTS = "PNG/Default size/Ship parts/"
CELL_W, CELL_H = 190, 390
ZOOM = 2.2


def loader(zf):
    cache = {}

    def get(name, sx=1.0, sy=1.0, flip=False):
        key = (name, sx, sy, flip)
        if key not in cache:
            im = Image.open(io.BytesIO(zf.read(PARTS + name))).convert("RGBA")
            if flip:
                im = im.transpose(Image.FLIP_LEFT_RIGHT)
            if sx != 1.0 or sy != 1.0:
                im = im.resize((max(1, round(im.width * sx)), max(1, round(im.height * sy))), Image.LANCZOS)
            cache[key] = im
        return cache[key]

    return get


def put(canvas, im, cx, cy):
    """Teil mit Mittelpunkt (cx, cy) auf die Leinwand legen."""
    canvas.alpha_composite(im, (round(cx - im.width / 2), round(cy - im.height / 2)))


def build(get, spec):
    w, h = 110, 172
    ship = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    mid = w / 2
    top = 12  # Oberkante des Rumpfs

    hull = get(spec["hull"], spec.get("hw", 1.0), spec.get("hl", 1.0))
    put(ship, hull, mid, top + hull.height / 2)
    hy0, hy1 = top, top + hull.height

    # Kanonen seitlich am Rumpf (links gespiegelt)
    for k in range(spec.get("cannons", 0)):
        y = hy0 + hull.height * (0.30 + 0.5 * k / max(spec["cannons"] - 1, 1)) if spec["cannons"] > 1 else hy0 + hull.height * 0.5
        c = get("cannon.png", 0.55, 0.55)
        put(ship, c, mid + hull.width / 2 - 1, y)
        put(ship, get("cannon.png", 0.55, 0.55, flip=True), mid - hull.width / 2 + 1, y)

    for (sail, sx, sy, y) in spec["sails"]:
        im = get(sail, sx, sy)
        put(ship, im, mid, hy0 + y)

    if spec.get("nest"):
        put(ship, get("nest.png"), mid, hy0 + spec["nest"])
    for (flag, y) in spec.get("flags", []):
        put(ship, get(flag), mid, hy0 + y)
    return ship


SHIPS = [
    ("Schaluppe", dict(hull="hullSmall (1).png", sails=[("sailLarge (7).png", 0.75, 0.9, 38)], cannons=1)),
    ("Klipper", dict(hull="hullSmall (2).png", hl=1.18, sails=[("sailLarge (7).png", 0.8, 0.85, 26), ("sailLarge (7).png", 0.8, 0.85, 62)], cannons=0, flags=[("flag (2).png", 4)])),
    ("Brigg", dict(hull="hullLarge (1).png", sails=[("sailLarge (3).png", 1.0, 1.0, 30), ("sailLarge (3).png", 0.7, 0.8, 68)], cannons=2, flags=[("flag (3).png", 4)])),
    ("Fregatte", dict(hull="hullLarge (2).png", hl=1.15, sails=[("sailLarge (5).png", 0.95, 0.72, 24), ("sailLarge (5).png", 0.95, 0.72, 54), ("sailLarge (5).png", 0.7, 0.55, 82)], cannons=3, nest=15, flags=[("flag (5).png", 2)])),
    ("Galeone", dict(hull="hullLarge (3).png", hw=1.3, hl=1.38, sails=[("sailLarge (2).png", 1.15, 0.8, 26), ("sailLarge (2).png", 1.15, 0.8, 62), ("sailLarge (2).png", 0.8, 0.6, 94)], cannons=5, nest=17, flags=[("flag (2).png", 2)])),
]


def main(zip_path, out):
    zf = zipfile.ZipFile(zip_path)
    get = loader(zf)
    try:
        font = ImageFont.truetype("arial.ttf", 15)
    except OSError:
        font = ImageFont.load_default()

    sheet = Image.new("RGB", (CELL_W * len(SHIPS), CELL_H + 30), (9, 56, 92))
    d = ImageDraw.Draw(sheet)
    for i, (name, spec) in enumerate(SHIPS):
        ship = build(get, spec)
        big = ship.resize((round(ship.width * ZOOM), round(ship.height * ZOOM)), Image.LANCZOS)
        x = i * CELL_W + (CELL_W - big.width) // 2
        sheet.paste(big, (x, 12), big)
        d.text((i * CELL_W + 12, CELL_H + 6), name, fill=(226, 232, 240), font=font)
    sheet.save(out)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
