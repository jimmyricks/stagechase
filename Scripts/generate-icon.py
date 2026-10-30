#!/usr/bin/env python3
from pathlib import Path
import math

from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
SIZE = 1024


def make_icon():
    image = Image.new("RGB", (SIZE, SIZE))
    pixels = image.load()
    for y in range(SIZE):
        for x in range(SIZE):
            t = (x * 0.58 + y * 0.42) / (SIZE - 1)
            glow = max(0.0, 1.0 - math.hypot(x - 705, y - 310) / 850)
            pixels[x, y] = (
                int(8 + 11 * t + 7 * glow),
                int(22 + 35 * t + 27 * glow),
                int(34 + 28 * t + 23 * glow),
            )

    glow_layer = Image.new("RGBA", image.size, (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow_layer)
    glow_draw.ellipse((470, 95, 1040, 665), fill=(55, 242, 206, 60))
    glow_draw.ellipse((565, 125, 955, 515), fill=(255, 117, 79, 40))
    glow_layer = glow_layer.filter(ImageFilter.GaussianBlur(95))
    image = Image.alpha_composite(image.convert("RGBA"), glow_layer)

    stage = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(stage)

    # Subtle projection grid gives the mark a stage-like sense of depth.
    for offset in range(-2, 8):
        x = 160 + offset * 125
        draw.line((x, 205, x - 92, 790), fill=(132, 225, 213, 20), width=2)
    for y in (275, 395, 515, 635, 755):
        draw.line((120, y, 885, y), fill=(132, 225, 213, 22), width=2)

    frame = [(174, 236), (779, 236), (857, 707), (130, 707)]
    draw.polygon(frame, fill=(8, 31, 44, 128), outline=(95, 224, 198, 150))
    draw.line(frame + [frame[0]], fill=(108, 236, 208, 115), width=4, joint="curve")

    # Three repeated slice planes form a left-to-right chase with a bright active frame.
    panels = [
        ([(222, 524), (404, 524), (386, 628), (204, 628)], (63, 180, 169, 155)),
        ([(397, 408), (595, 408), (576, 519), (378, 519)], (91, 218, 190, 205)),
        ([(574, 288), (788, 288), (767, 406), (553, 406)], (255, 118, 79, 255)),
    ]

    for polygon, color in panels[:2]:
        draw.polygon(polygon, fill=color)
        draw.line(polygon + [polygon[0]], fill=(160, 255, 228, 170), width=3, joint="curve")

    active_glow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(active_glow)
    active_polygon = panels[2][0]
    glow_draw.polygon(active_polygon, fill=(255, 111, 72, 185))
    active_glow = active_glow.filter(ImageFilter.GaussianBlur(34))
    image = Image.alpha_composite(image, active_glow)

    stage_draw = ImageDraw.Draw(stage)
    stage_draw.polygon(active_polygon, fill=(255, 126, 84, 255))
    stage_draw.line(active_polygon + [active_polygon[0]], fill=(255, 224, 191, 255), width=5, joint="curve")

    # Bright travel line and five step markers anchor the icon at small sizes.
    stage_draw.line((275, 682, 718, 239), fill=(255, 199, 126, 190), width=5)
    for index, x in enumerate((325, 418, 511, 604, 697)):
        radius = 13 if index == 3 else 9
        color = (255, 154, 105, 255) if index == 3 else (175, 238, 219, 210)
        stage_draw.ellipse((x - radius, 832 - radius, x + radius, 832 + radius), fill=color)
        if index < 4:
            stage_draw.rounded_rectangle((x + 24, 829, x + 68, 835), radius=3, fill=(140, 202, 192, 115))

    image = Image.alpha_composite(image, stage)

    # A restrained highlight keeps the icon dimensional without adding text.
    highlight = Image.new("RGBA", image.size, (0, 0, 0, 0))
    highlight_draw = ImageDraw.Draw(highlight)
    highlight_draw.arc((66, 68, 958, 960), 196, 302, fill=(195, 255, 236, 42), width=3)
    highlight = highlight.filter(ImageFilter.GaussianBlur(1))
    return Image.alpha_composite(image, highlight).convert("RGB")


def main():
    resource_dir = ROOT / "Resources"
    iconset_dir = ROOT / ".build" / "StageChaseIcon.iconset"
    iconset_dir.mkdir(parents=True, exist_ok=True)
    icon = make_icon()
    icon.save(resource_dir / "StageChaseIcon.png", optimize=True)

    for size in (16, 32, 128, 256, 512):
        base = icon.resize((size, size), Image.Resampling.LANCZOS)
        base.save(iconset_dir / f"icon_{size}x{size}.png")
        doubled = size * 2
        base2x = icon.resize((doubled, doubled), Image.Resampling.LANCZOS)
        base2x.save(iconset_dir / f"icon_{size}x{size}@2x.png")

    import subprocess
    subprocess.run(
        ["iconutil", "-c", "icns", str(iconset_dir), "-o", str(resource_dir / "StageChaseIcon.icns")],
        check=True,
    )
    print(f"Generated {resource_dir / 'StageChaseIcon.icns'}")


if __name__ == "__main__":
    main()
