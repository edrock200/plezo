#!/usr/bin/env python3
"""Generate Plezilo's icon and logo for every platform from one geometric design.

Plezilo is a fork of Plezy, and Plezy's logo and app icons are the Plezy project's trademark
(TRADEMARKS.md), so Plezilo draws its own: a white "orbit" mark (an open ring, a satellite dot in
the ring's gap and a solid core) on an indigo-to-teal gradient. It is unrelated to Plezy's logo and
to Silo's logo, and must not be changed to resemble either.

The mark is defined once below, in a 1024 x 1024 canvas, and written both as vectors (SVG for
Flutter and Icon Composer, VectorDrawable XML for Android) and as PNG/WebP/ICO rasters drawn with
Pillow (4x supersampled), so the script needs only Python 3 and Pillow:

    python3 scripts/make_plezilo_icon.py

Outputs (all committed; re-run after changing the design):
* assets/plezilo.png, assets/plezilo.svg: the app icon (rounded gradient square) used in the app
  (About, sign-in) and by the Linux packaging scripts.
* assets/plezilo_mark.svg: the mark alone, painted with the gradient, for the in-app splash.
* android/app/src/main/res: adaptive icon layers (drawable/ic_launcher_{foreground,background,
  monochrome}.xml), the Android 12 splash mark (drawable/ic_splash_mark.xml), legacy launcher PNGs
  (mipmap-*/ic_launcher.png), the Android TV banner (drawable-*/tv_banner.png) and the
  notification icon (drawable-*/ic_stat_notification.png).
* ios/plezilo.icon, macos/plezilo.icon: Icon Composer bundles (gradient fill + white mark layer).
* tvos/Runner/Assets.xcassets/AppIcon.brandassets: the layered app icon (Back/Middle/Front, also
  the App Store size) and the Top Shelf images.
* windows/runner/resources/app_icon.ico and windows/msix/assets/*.png.
* assets/app_icons/previews/default-{tvos,androidtv}.webp: the default icon as the TV launchers
  draw it (the app-icon picker's thumbnails; the picker is hidden while there are no alternates).
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:  # pragma: no cover - tooling message
    sys.exit("Pillow is required: python3 -m pip install Pillow")

ROOT = Path(__file__).resolve().parents[1]

# ---------------------------------------------------------------------------------------------
# The design, in a 1024 x 1024 canvas.
# ---------------------------------------------------------------------------------------------
CANVAS = 1024
GRADIENT_START = (0x4F, 0x46, 0xE5)  # indigo, top left
GRADIENT_END = (0x0E, 0xA5, 0xB7)  # teal, bottom right
WHITE = (0xFF, 0xFF, 0xFF)

CENTER = 512.0
RING_RADIUS = 208.0  # centre line of the ring
RING_WIDTH = 92.0
GAP_ANGLE = -45.0  # the satellite sits in the ring's gap, top right (degrees, y down)
GAP_HALF_SPAN = 42.0  # half the gap, in degrees
SATELLITE_RADIUS = 54.0
CORE_RADIUS = 74.0
# Corner radius of the rounded-square app icon, as on iOS-style squircles (approximated).
ICON_CORNER = 0.225


def _hex(rgb: tuple[int, int, int]) -> str:
    return "#{:02X}{:02X}{:02X}".format(*rgb)


def _polar(angle_deg: float, radius: float, cx: float = CENTER, cy: float = CENTER) -> tuple[float, float]:
    a = math.radians(angle_deg)
    return cx + radius * math.cos(a), cy + radius * math.sin(a)


ARC_START = GAP_ANGLE + GAP_HALF_SPAN  # -3 degrees
ARC_END = GAP_ANGLE - GAP_HALF_SPAN + 360.0  # 273 degrees, drawn clockwise from ARC_START
SATELLITE = _polar(GAP_ANGLE, RING_RADIUS)


def _f(v: float) -> str:
    return f"{v:.2f}".rstrip("0").rstrip(".")


def ring_path() -> str:
    """The ring's centre line as an SVG/VectorDrawable arc (stroked with round caps)."""
    x0, y0 = _polar(ARC_START, RING_RADIUS)
    x1, y1 = _polar(ARC_END, RING_RADIUS)
    return f"M{_f(x0)},{_f(y0)} A{_f(RING_RADIUS)},{_f(RING_RADIUS)} 0 1,1 {_f(x1)},{_f(y1)}"


def circle_path(cx: float, cy: float, r: float) -> str:
    return f"M{_f(cx - r)},{_f(cy)} a{_f(r)},{_f(r)} 0 1,0 {_f(2 * r)},0 a{_f(r)},{_f(r)} 0 1,0 {_f(-2 * r)},0 Z"


def dots_path() -> str:
    return circle_path(*SATELLITE, SATELLITE_RADIUS) + " " + circle_path(CENTER, CENTER, CORE_RADIUS)


# ---------------------------------------------------------------------------------------------
# Vectors
# ---------------------------------------------------------------------------------------------
def svg_mark(paint: str, defs: str = "", background: str = "") -> str:
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">\n'
        f"{defs}{background}"
        f'  <path d="{ring_path()}" fill="none" stroke="{paint}" stroke-width="{_f(RING_WIDTH)}" '
        'stroke-linecap="round"/>\n'
        f'  <path d="{dots_path()}" fill="{paint}"/>\n'
        "</svg>\n"
    )


GRADIENT_DEFS = (
    "  <defs>\n"
    '    <linearGradient id="g" x1="0" y1="0" x2="1024" y2="1024" gradientUnits="userSpaceOnUse">\n'
    f'      <stop offset="0" stop-color="{_hex(GRADIENT_START)}"/>\n'
    f'      <stop offset="1" stop-color="{_hex(GRADIENT_END)}"/>\n'
    "    </linearGradient>\n"
    "  </defs>\n"
)


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def vector_drawable(body: str, comment: str) -> str:
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        f"<!-- {comment} Generated by scripts/make_plezilo_icon.py; do not edit. -->\n"
        '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
        '    xmlns:aapt="http://schemas.android.com/aapt"\n'
        '    android:width="108dp"\n'
        '    android:height="108dp"\n'
        '    android:viewportWidth="1024"\n'
        '    android:viewportHeight="1024">\n'
        f"{body}"
        "</vector>\n"
    )


def _vd_gradient(attr: str) -> str:
    return (
        f'        <aapt:attr name="android:{attr}">\n'
        '            <gradient android:type="linear" android:startX="0" android:startY="0"\n'
        '                android:endX="1024" android:endY="1024">\n'
        f'                <item android:offset="0" android:color="#FF{_hex(GRADIENT_START)[1:]}"/>\n'
        f'                <item android:offset="1" android:color="#FF{_hex(GRADIENT_END)[1:]}"/>\n'
        "            </gradient>\n"
        "        </aapt:attr>\n"
    )


def vd_mark(color: str | None, scale: float = 1.0) -> str:
    """The mark as VectorDrawable paths; [color] None paints it with the gradient."""
    pivot = f'android:pivotX="512" android:pivotY="512" android:scaleX="{scale}" android:scaleY="{scale}"'
    if color is None:
        stroke = (
            f'    <path android:pathData="{ring_path()}" android:strokeWidth="{_f(RING_WIDTH)}"\n'
            '        android:strokeLineCap="round">\n' + _vd_gradient("strokeColor") + "    </path>\n"
        )
        fill = f'    <path android:pathData="{dots_path()}">\n' + _vd_gradient("fillColor") + "    </path>\n"
    else:
        stroke = (
            f'    <path android:pathData="{ring_path()}" android:strokeColor="{color}"\n'
            f'        android:strokeWidth="{_f(RING_WIDTH)}" android:strokeLineCap="round"/>\n'
        )
        fill = f'    <path android:pathData="{dots_path()}" android:fillColor="{color}"/>\n'
    inner = "".join("    " + line + "\n" for line in (stroke + fill).splitlines())
    return f"    <group {pivot}>\n{inner}    </group>\n"


# ---------------------------------------------------------------------------------------------
# Rasters
# ---------------------------------------------------------------------------------------------
SS = 4  # supersampling factor


def gradient(width: int, height: int) -> Image.Image:
    """Diagonal gradient from GRADIENT_START (top left) to GRADIENT_END (bottom right)."""
    w, h = max(width // 8, 2), max(height // 8, 2)
    small = Image.new("RGB", (w, h))
    px = small.load()
    for y in range(h):
        for x in range(w):
            t = (x / (w - 1) * width + y / (h - 1) * height) / (width + height)
            px[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(GRADIENT_START, GRADIENT_END))
    return small.resize((width, height), Image.BICUBIC)


def mark_mask(size: int, mark_scale: float = 1.0, offset: tuple[float, float] = (0, 0), canvas=None) -> Image.Image:
    """Alpha mask of the mark. The 1024 design is scaled by size/1024*mark_scale about its centre,
    then moved by [offset] (in output pixels). [canvas] is the output (width, height)."""
    cw, ch = canvas or (size, size)
    big = Image.new("L", (cw * SS, ch * SS), 0)
    d = ImageDraw.Draw(big)
    k = size / CANVAS * mark_scale * SS
    ox = cw * SS / 2 + offset[0] * SS
    oy = ch * SS / 2 + offset[1] * SS

    def pt(x: float, y: float) -> tuple[float, float]:
        return ox + (x - CENTER) * k, oy + (y - CENTER) * k

    def disc(x: float, y: float, r: float) -> None:
        cx, cy = pt(x, y)
        d.ellipse([cx - r * k, cy - r * k, cx + r * k, cy + r * k], fill=255)

    outer = RING_RADIUS + RING_WIDTH / 2
    cx, cy = pt(CENTER, CENTER)
    d.arc(
        [cx - outer * k, cy - outer * k, cx + outer * k, cy + outer * k],
        ARC_START,
        ARC_END,
        fill=255,
        width=max(1, round(RING_WIDTH * k)),
    )
    for angle in (ARC_START, ARC_END):
        disc(*_polar(angle, RING_RADIUS), RING_WIDTH / 2)
    disc(*SATELLITE, SATELLITE_RADIUS)
    disc(CENTER, CENTER, CORE_RADIUS)
    return big.resize((cw, ch), Image.LANCZOS)


def rounded_mask(width: int, height: int, radius: float) -> Image.Image:
    big = Image.new("L", (width * SS, height * SS), 0)
    ImageDraw.Draw(big).rounded_rectangle([0, 0, width * SS - 1, height * SS - 1], radius=radius * SS, fill=255)
    return big.resize((width, height), Image.LANCZOS)


def app_icon(size: int, rounded: bool = True, margin: float = 0.0, mark_scale: float = 1.0) -> Image.Image:
    """The full icon: gradient (rounded) square with the white mark, on a transparent canvas."""
    inner = round(size * (1 - 2 * margin))
    tile = gradient(inner, inner).convert("RGBA")
    tile.paste(Image.new("RGBA", (inner, inner), WHITE + (255,)), (0, 0), mark_mask(inner, mark_scale))
    if rounded:
        tile.putalpha(rounded_mask(inner, inner, inner * ICON_CORNER))
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(tile, ((size - inner) // 2, (size - inner) // 2), tile)
    return out


def white_mark(width: int, height: int, mark_size: float, offset=(0, 0)) -> Image.Image:
    out = Image.new("RGBA", (width, height), WHITE + (0,))
    out.putalpha(mark_mask(round(mark_size), offset=offset, canvas=(width, height)))
    return out


def _font(px: int):
    for candidate in (
        "/usr/share/fonts/opentype/inter/InterDisplay-Bold.otf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "C:/Windows/Fonts/arialbd.ttf",
    ):
        if Path(candidate).exists():
            return ImageFont.truetype(candidate, px)
    return None


def banner(width: int, height: int, with_name: bool = True, transparent: bool = False) -> Image.Image:
    """A wide tile: the mark, and the name "Plezilo" beside it when a bold font is available."""
    base = Image.new("RGBA", (width, height), (0, 0, 0, 0)) if transparent else gradient(width, height).convert("RGBA")
    mark_px = height * 0.62 / 0.52  # the mark spans ~52% of its 1024 canvas
    font = _font(round(height * 0.30)) if with_name else None
    if font is None:
        base.alpha_composite(white_mark(width, height, mark_px))
        return base
    text = "Plezilo"
    draw = ImageDraw.Draw(base)
    left, top, right, bottom = draw.textbbox((0, 0), text, font=font)
    text_w = right - left
    mark_w = mark_px * 0.52
    gap = height * 0.12
    total = mark_w + gap + text_w
    start = (width - total) / 2
    base.alpha_composite(white_mark(width, height, mark_px, offset=(start + mark_w / 2 - width / 2, 0)))
    draw.text((start + mark_w + gap - left, (height - (bottom - top)) / 2 - top), text, font=font, fill=WHITE)
    return base


def save_png(img: Image.Image, path: Path, mode: str | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if mode:
        img = img.convert(mode)
    img.save(path, optimize=True)


# ---------------------------------------------------------------------------------------------
# Platforms
# ---------------------------------------------------------------------------------------------
def make_shared() -> None:
    rect = (
        f'  <rect width="1024" height="1024" rx="{_f(CANVAS * ICON_CORNER)}" fill="url(#g)"/>\n'
    )
    write(ROOT / "assets/plezilo.svg", svg_mark("#FFFFFF", GRADIENT_DEFS, rect))
    write(ROOT / "assets/plezilo_mark.svg", svg_mark("url(#g)", GRADIENT_DEFS))
    save_png(app_icon(1024), ROOT / "assets/plezilo.png")


def make_android() -> None:
    res = ROOT / "android/app/src/main/res"
    # The adaptive foreground keeps the mark inside the 66dp safe zone (the mark spans ~52% of 108dp).
    write(res / "drawable/ic_launcher_foreground.xml", vector_drawable(vd_mark("#FFFFFFFF"), "Plezilo mark, white."))
    write(res / "drawable/ic_launcher_monochrome.xml", vector_drawable(vd_mark("#FFFFFFFF"), "Themed-icon silhouette."))
    write(
        res / "drawable/ic_splash_mark.xml",
        vector_drawable(vd_mark(None), "Plezilo mark in the brand gradient, for the Android 12+ splash screen."),
    )
    background = (
        '    <path android:pathData="M0,0h1024v1024h-1024z">\n' + _vd_gradient("fillColor") + "    </path>\n"
    )
    write(res / "drawable/ic_launcher_background.xml", vector_drawable(background, "Plezilo gradient."))
    for density, size in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
        save_png(app_icon(size, margin=1 / 12), res / f"mipmap-{density}/ic_launcher.png")
    for density, (w, h) in {"xhdpi": (320, 180), "xxhdpi": (480, 270), "xxxhdpi": (640, 360)}.items():
        save_png(banner(w, h), res / f"drawable-{density}/tv_banner.png", "RGB")
    for density, size in {"mdpi": 24, "hdpi": 36, "xhdpi": 48, "xxhdpi": 72, "xxxhdpi": 96}.items():
        save_png(white_mark(size, size, size * 1.6), res / f"drawable-{density}/ic_stat_notification.png")


def make_icon_composer() -> None:
    icon_json = {
        "fill": {"automatic-gradient": "display-p3:0.30980,0.27451,0.89804,1.00000"},
        "groups": [
            {
                "layers": [
                    {
                        "glass": True,
                        "hidden": False,
                        "image-name": "plezilo-mark.svg",
                        "name": "plezilo-mark",
                        "position": {"scale": 1, "translation-in-points": [0, 0]},
                    }
                ],
                "shadow": {"kind": "neutral", "opacity": 0.5},
                "specular": True,
                "translucency": {"enabled": False, "value": 0.5},
            }
        ],
        "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
    }
    for platform in ("ios", "macos"):
        bundle = ROOT / platform / "plezilo.icon"
        for stale in (bundle / "Assets").glob("*"):
            stale.unlink()
        write(bundle / "Assets/plezilo-mark.svg", svg_mark("#FFFFFF"))
        write(bundle / "icon.json", json.dumps(icon_json, indent=2) + "\n")


def make_tvos() -> None:
    brand = ROOT / "tvos/Runner/Assets.xcassets/AppIcon.brandassets"
    stacks = {
        "App Icon.imagestack": {"": (400, 240), "@2x": (800, 480)},
        "App Icon - App Store.imagestack": {"": (1280, 768)},
    }
    for stack, sizes in stacks.items():
        for suffix, (w, h) in sizes.items():
            layers = brand / stack
            mark_px = h * 0.62 / 0.52
            save_png(gradient(w, h), layers / f"Back.imagestacklayer/Content.imageset/Back{suffix}.png", "RGB")
            save_png(Image.new("RGBA", (w, h), (0, 0, 0, 0)), layers / f"Middle.imagestacklayer/Content.imageset/Middle{suffix}.png")
            save_png(white_mark(w, h, mark_px), layers / f"Front.imagestacklayer/Content.imageset/Front{suffix}.png")
    save_png(banner(1920, 720), brand / "Top Shelf Image.imageset/top-shelf.png", "RGB")
    save_png(banner(2320, 720), brand / "Top Shelf Image Wide.imageset/top-shelf-wide.png", "RGB")
    save_png(banner(4640, 1440), brand / "Top Shelf Image Wide.imageset/top-shelf-wide@2x.png", "RGB")


def make_windows() -> None:
    ico = app_icon(256, margin=1 / 32)
    ico.save(
        ROOT / "windows/runner/resources/app_icon.ico",
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )
    msix = ROOT / "windows/msix/assets"
    squares = {
        "Square44x44Logo.png": 44,
        "Square44x44Logo.scale-200.png": 88,
        "Square150x150Logo.png": 150,
        "Square150x150Logo.scale-200.png": 300,
        "Square310x310Logo.png": 310,
        "StoreLogo.png": 50,
    }
    for name, size in squares.items():
        save_png(app_icon(size, margin=0.08), msix / name)
    for size in (16, 24, 32, 48, 256):
        for form in ("", "_altform-unplated", "_altform-lightunplated"):
            save_png(app_icon(size, margin=1 / 32), msix / f"Square44x44Logo.targetsize-{size}{form}.png")
    save_png(banner(310, 150, transparent=False), msix / "Wide310x150Logo.png")
    save_png(banner(620, 300, transparent=False), msix / "SplashScreen.png")


def make_previews() -> None:
    previews = ROOT / "assets/app_icons/previews"
    tv = Image.new("RGB", (400, 240))
    tv.paste(gradient(400, 240))
    tv.paste(white_mark(400, 240, 240 * 0.62 / 0.52).convert("RGB"), (0, 0), white_mark(400, 240, 240 * 0.62 / 0.52))
    banner_img = banner(640, 360).convert("RGB")
    for name, img in (("default-tvos.webp", tv), ("default-androidtv.webp", banner_img)):
        w, h = img.size
        side = min(w, h)
        crop = img.crop(((w - side) // 2, (h - side) // 2, (w + side) // 2, (h + side) // 2)).resize((216, 216), Image.LANCZOS)
        crop.save(previews / name, quality=90)


def main() -> None:
    make_shared()
    make_android()
    make_icon_composer()
    make_tvos()
    make_windows()
    make_previews()
    print("Plezilo icons written.")


if __name__ == "__main__":
    main()
