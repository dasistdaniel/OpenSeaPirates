"""
Erzeugt die Schiffs-Sprites aller Klassen und Farben aus den Einzelteilen des Kenney Pirate Pack.

    python scripts/ship_sprites.py <pfad/zur/pirate-pack.zip> priv/static/images/ships

Schreibt `<klasse>_<farbe>.png` (5 Klassen × 6 Farben) sowie `_reefed` (Segel kleiner) und
`_studding` (Segel größer) für die Segelstufen; nur die Segel ändern sich, der Rumpf bleibt gleich. Bug zeigt nach unten (wie die fertigen
Schiffe des Packs); der Bildmittelpunkt liegt auf der Rumpfmitte, damit das Schiff darum dreht.
Maßstab im Spiel: 1,5 WE entsprechen 113 Pixeln.
"""
import sys
from pathlib import Path

import zipfile
from PIL import Image

from ship_preview import loader, put

# Farbe (wie im Spiel) -> Segel- und Flaggennummer im Pack
COLORS = {"yellow": 6, "blue": 5, "red": 3, "green": 4, "black": 2, "white": 1}
COLOR_ORDER = ["yellow", "blue", "red", "green", "black", "white"]

# Hülle: Rumpfteil, Streckung, Segel (Teilname, x, y, Lage), Kanonen, Krähennest, Flaggenlage
CLASSES = {
    "schaluppe": dict(hull="hullSmall (1).png", sails=[(0.75, 0.9, 38)], cannons=1, flag=None),
    "klipper": dict(hull="hullSmall (2).png", hl=1.18, sails=[(0.8, 0.85, 26), (0.8, 0.85, 62)], cannons=0, flag=4),
    "brigg": dict(hull="hullLarge (1).png", sails=[(1.0, 1.0, 30), (0.7, 0.8, 68)], cannons=2, flag=4),
    "fregatte": dict(hull="hullLarge (2).png", hl=1.15, sails=[(0.95, 0.72, 24), (0.95, 0.72, 54), (0.7, 0.55, 82)], cannons=3, nest=15, flag=2),
    "galeone": dict(hull="hullLarge (3).png", hw=1.3, hl=1.38, sails=[(1.15, 0.8, 26), (1.15, 0.8, 62), (0.8, 0.6, 94)], cannons=5, nest=17, flag=2),
}


# Segelgröße je Stufe (Faktor auf die Segelbilder)
SAIL_SCALE = {"": 1.0, "_reefed": 0.75, "_studding": 1.2}


def build(get, spec, sail_n, sail_k=1.0):
    w, h = 110, 172
    ship = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    mid = w / 2
    top = 12

    hull = get(spec["hull"], spec.get("hw", 1.0), spec.get("hl", 1.0))
    hull_cy = top + hull.height / 2
    put(ship, hull, mid, hull_cy)
    hy0 = top

    n = spec.get("cannons", 0)
    for k in range(n):
        y = hy0 + hull.height * (0.30 + 0.5 * k / max(n - 1, 1)) if n > 1 else hy0 + hull.height * 0.5
        put(ship, get("cannon.png", 0.55, 0.55), mid + hull.width / 2 - 1, y)
        put(ship, get("cannon.png", 0.55, 0.55, flip=True), mid - hull.width / 2 + 1, y)

    for (sx, sy, y) in spec["sails"]:
        put(ship, get(f"sailLarge ({sail_n}).png", sx * sail_k, sy * sail_k), mid, hy0 + y)

    if spec.get("nest"):
        put(ship, get("nest.png"), mid, hy0 + spec["nest"])
    if spec.get("flag") is not None:
        put(ship, get(f"flag ({sail_n}).png"), mid, hy0 + spec["flag"])

    # Rumpfmitte in die Bildmitte legen (symmetrisch zuschneiden)
    bbox = ship.getbbox()
    half_h = max(hull_cy - bbox[1], bbox[3] - hull_cy) + 2
    half_w = max(mid - bbox[0], bbox[2] - mid) + 2
    box = (round(mid - half_w), round(hull_cy - half_h), round(mid + half_w), round(hull_cy + half_h))
    return ship.crop(box)


def main(zip_path, out_dir):
    get = loader(zipfile.ZipFile(zip_path))
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    for name, spec in CLASSES.items():
        for color in COLOR_ORDER:
            for suffix, k in SAIL_SCALE.items():
                build(get, spec, COLORS[color], k).save(out / f"{name}_{color}{suffix}.png")
    print(f"{len(CLASSES) * len(COLOR_ORDER) * len(SAIL_SCALE)} Sprites in {out}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
