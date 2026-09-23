from pathlib import Path
from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parents[1] / "icons"
OUT.mkdir(parents=True, exist_ok=True)

def make(size: int) -> None:
    img = Image.new("RGBA", (size, size), (37, 99, 235, 255))
    d = ImageDraw.Draw(img)

    # Soft diagonal two-tone background.
    for y in range(size):
        t = y / max(1, size - 1)
        r = int(37 * (1 - t) + 79 * t)
        g = int(99 * (1 - t) + 70 * t)
        b = int(235 * (1 - t) + 229 * t)
        d.line((0, y, size, y), fill=(r, g, b, 255))

    margin = int(size * 0.205)
    top = int(size * 0.23)
    bottom = int(size * 0.77)
    radius = int(size * 0.085)
    d.rounded_rectangle(
        (margin, top, size - margin, bottom),
        radius=radius,
        fill=(255, 255, 255, 248),
    )

    left = int(size * 0.29)
    d.rounded_rectangle(
        (left, int(size * 0.32), int(size * 0.71), int(size * 0.385)),
        radius=int(size * 0.03),
        fill=(37, 99, 235, 255),
    )
    d.rounded_rectangle(
        (left, int(size * 0.44), int(size * 0.61), int(size * 0.485)),
        radius=int(size * 0.022),
        fill=(199, 210, 254, 255),
    )
    d.rounded_rectangle(
        (left, int(size * 0.54), int(size * 0.66), int(size * 0.585)),
        radius=int(size * 0.022),
        fill=(199, 210, 254, 255),
    )

    cx, cy = int(size * 0.665), int(size * 0.675)
    rr = int(size * 0.125)
    d.ellipse((cx - rr, cy - rr, cx + rr, cy + rr), fill=(16, 185, 129, 255))
    w = max(3, int(size * 0.035))
    d.line(
        (
            int(size * 0.605), int(size * 0.676),
            int(size * 0.646), int(size * 0.716),
            int(size * 0.727), int(size * 0.62),
        ),
        fill=(255, 255, 255, 255),
        width=w,
        joint="curve",
    )

    img.save(OUT / f"helper-icon-{size}.png", optimize=True)

for s in (180, 192, 512):
    make(s)
