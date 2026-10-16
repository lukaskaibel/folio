#!/usr/bin/env python3
"""Draws Notebook's app icon: a leather notebook with an elastic band and a ribbon, lying on a ground.

  notebook.py icon <out dir>     <out dir>/AppIcon.icon, the oxblood notebook in light and dark (the app's own icon)
  notebook.py passes <out dir>   the neutral passes behind Settings › App Icon (see NotebookIcon.swift)
  notebook.py leather <out>      the cover's grain alone as a seamless tile, for the website's leather buttons
                                 (Website/images/leather.webp; needs only NumPy and Pillow)

Tools/AppIcon/make.sh runs all three and renders the passes with Apple's ictool. Needs Python 3 with NumPy and Pillow,
and rsvg-convert (brew install librsvg).

The layers are drawn as SVG, the leather grain is added to the cover with NumPy, and Icon Composer's file format puts
them together, so the system adds the glass, the shadows and the tinted and clear looks.
"""
import colorsys, json, os, subprocess, sys
import numpy as np
from PIL import Image

# The cover on the 1024 canvas.
X, Y, W, H, R = 232, 122, 560, 772, 64

# The notebook the app ships with. Keep in step with NotebookLook.standard in NotebookIcon.swift.
STANDARD = {"leather": "#A8403F", "ribbon": "#E9B04A", "band": "leather", "ground": "#EFEAE2"}

# The albedo a part gets in its pass; below white so the grain's highlights never clip.
PASS_GREY = "#B4B4B4"


# Colours. The app derives the same shades from the same base colours (NotebookIcon.swift).

def rgb(hex_):
    return tuple(int(hex_[i:i + 2], 16) / 255 for i in (1, 3, 5))

def hex_(c):
    return "#" + "".join(f"{round(min(max(v, 0), 1) * 255):02X}" for v in c)

def scaled(hex_colour, saturation, brightness):
    h, s, v = colorsys.rgb_to_hsv(*rgb(hex_colour))
    return hex_(colorsys.hsv_to_rgb(h, min(s * saturation, 1), min(v * brightness, 1)))

def leather_shades(c):
    """Cover gradient (top, bottom) in light and in dark, and the elastic band's tone."""
    return {"light": (c, scaled(c, 1.18, 0.64)), "dark": (scaled(c, 0.88, 1.16), scaled(c, 1.08, 0.79)),
            "band": scaled(c, 1.25, 0.45)}

def ground_shades(c):
    h, s, v = colorsys.rgb_to_hsv(*rgb(c))
    dark_top = hex_(colorsys.hsv_to_rgb(h, s * 0.6, max(v * 0.30, 0.18)))
    return {"light": (c, scaled(c, 1.1, 0.88)), "dark": (dark_top, scaled(dark_top, 1.0, 0.55))}


# Drawing.

def rect(x, y, w, h, r, fill):
    return f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="{r:.1f}" fill="{fill}"/>'

def faded(colour, opacity):
    return f'{colour}" fill-opacity="{opacity}'

def cover(fill): return rect(X, Y, W, H, R, fill)
def band(fill): return rect(X + W - 100, Y - 3, 40, H + 6, 6, fill)
def hinge(opacity): return rect(X + 46, Y + 10, 8, H - 20, 4, faded("#000000", opacity))
def pages(fill): return rect(X + 22, Y + 16, W, H - 32, 50, fill)

def ribbon(fill, drop=54, width=46):
    x, top, bottom = X + 140, Y + H - 40, Y + H + drop
    return f'<path d="M{x},{top} H{x + width} V{bottom} L{x + width / 2},{bottom - 22} L{x},{bottom} Z" fill="{fill}"/>'

def linear_gradient(id_, top, bottom):
    return (f'<linearGradient id="{id_}" gradientUnits="userSpaceOnUse" x1="0" y1="{Y}" x2="0" y2="{Y + H}">'
            f'<stop offset="0" stop-color="{top}"/><stop offset="1" stop-color="{bottom}"/></linearGradient>')

def write_png(path, body, defs=""):
    svg = path[:-4] + ".svg"
    with open(svg, "w") as f:
        f.write(f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
                f'<defs>{defs}</defs>{body}</svg>')
    subprocess.run(["rsvg-convert", "-w", "1024", "-h", "1024", "-o", path, svg], check=True)
    os.remove(svg)


# The leather grain: soft pebbles at two sizes, lit from the top left, with faint mottling.

def pebbles(size, cell, rng, wrap=False):
    """wrap: the cells fitted to the size and wrapped around its edges, so the result tiles without a seam."""
    if wrap:
        n = round(size / cell)
        cell = size / n
    else:
        n = int(size / cell) + 3
    points = rng.random((n, n, 2))
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    cx, cy = np.floor(xx / cell).astype(int), np.floor(yy / cell).astype(int)
    d1 = np.full((size, size), 1e9, np.float32)
    d2 = np.full((size, size), 1e9, np.float32)
    for oy in (-1, 0, 1):
        for ox in (-1, 0, 1):
            if wrap:
                gx, gy = cx + ox, cy + oy
                px, py = gx % n, gy % n
            else:
                gx, gy = np.clip(cx + ox, 0, n - 1), np.clip(cy + oy, 0, n - 1)
                px, py = gx, gy
            d = np.hypot(xx - (gx + points[py, px, 0]) * cell, yy - (gy + points[py, px, 1]) * cell)
            closer = d < d1
            d2 = np.where(closer, d1, np.minimum(d2, d))
            d1 = np.where(closer, d, d1)
    t = np.clip((d2 - d1) / (cell * 0.55), 0, 1)
    return t * t * (3 - 2 * t)

def grain(size=1024, seed=7, wrap=False):
    rng = np.random.default_rng(seed)
    e = 0.6 * pebbles(size, 8.5, rng, wrap) + 0.4 * pebbles(size, 15.0, rng, wrap)
    if wrap:
        gx = (np.roll(e, -1, 1) - np.roll(e, 1, 1)) / 2
        gy = (np.roll(e, -1, 0) - np.roll(e, 1, 0)) / 2
        # The mottling at the icon's scale, from noise tiled three by three so that its middle wraps too.
        k = max(2, round(24 * size / 1024))
        low = Image.fromarray((np.tile(rng.random((k, k)), (3, 3)) * 255).astype(np.uint8))
        low = low.resize((size * 3, size * 3), Image.BICUBIC).crop((size, size, size * 2, size * 2))
    else:
        gy, gx = np.gradient(e)
        low = Image.fromarray((rng.random((24, 24)) * 255).astype(np.uint8)).resize((size, size), Image.BICUBIC)
    mottle = (np.asarray(low).astype(np.float32) / 255 - 0.5) * 0.05
    return 0.93 + 0.08 * e - (gx + gy) * 0.9 + mottle + rng.normal(0, 1, (size, size)).astype(np.float32) * 0.01

GRAIN = None

def add_grain(path):
    global GRAIN
    if GRAIN is None:
        GRAIN = grain()
    a = np.asarray(Image.open(path).convert("RGBA")).astype(np.float32)
    a[..., :3] = np.clip(a[..., :3] * GRAIN[..., None], 0, 255)
    Image.fromarray(a.astype(np.uint8), "RGBA").save(path)


# Icon Composer documents.

def srgb(hex_colour, alpha=1.0):
    r, g, b = rgb(hex_colour)
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},{alpha:.5f}"

def fill(top, bottom):
    return {"linear-gradient": [srgb(top), srgb(bottom)],
            "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}}}

def document(path, grounds, layers, defs="", grained=()):
    """grounds: {"light": (top, bottom), "dark": (top, bottom)}.
    layers: [(group, [(layer, light svg, dark svg, glass)], shadow opacity)], front first."""
    assets = os.path.join(path, "Assets")
    os.makedirs(assets, exist_ok=True)
    groups = []
    for group, group_layers, shadow in layers:
        out = []
        for name, light, dark, glass in group_layers:
            for look, body in (("light", light), ("dark", dark)):
                png = os.path.join(assets, f"{name}-{look}.png")
                write_png(png, body, defs)
                if name in grained:
                    add_grain(png)
            out.append({"name": name, "glass": glass, "image-name-specializations": [
                {"value": f"{name}-light.png"}, {"value": f"{name}-dark.png", "appearance": "dark"}]})
        groups.append({"name": group, "layers": out,
                       "shadow": {"kind": "neutral" if shadow else "none", "opacity": shadow or 0.5},
                       "translucency": {"enabled": False, "value": 0.4}})
    doc = {"fill-specializations": [{"value": fill(*grounds["light"])},
                                    {"appearance": "dark", "value": fill(*grounds["dark"])}],
           "groups": groups, "supported-platforms": {"squares": "shared"}}
    with open(os.path.join(path, "icon.json"), "w") as f:
        json.dump(doc, f, indent=2)

def notebook(path, leather, ribbon_colour, band_colours, grounds, pages_colours=("#F1EEE8", "#C9C5BD")):
    """leather: {"light": (top, bottom), "dark": (top, bottom)} or one flat colour for a pass."""
    if isinstance(leather, str):
        defs, covers = "", (cover(leather), cover(leather))
    else:
        defs = linear_gradient("light", *leather["light"]) + linear_gradient("dark", *leather["dark"])
        covers = (cover("url(#light)"), cover("url(#dark)"))
    document(path, grounds, [
        ("Band", [("band", band(band_colours[0]), band(band_colours[1]), True)], 0.35),
        ("Cover", [("cover-detail", hinge(0.16), hinge(0.22), False), ("cover", *covers, True)], 0.55),
        ("Ribbon", [("ribbon", ribbon(ribbon_colour), ribbon(ribbon_colour), True)], 0.3),
        ("Pages", [("pages", pages(pages_colours[0]), pages(pages_colours[1]), True)], None),
    ], defs, grained=("cover",))


def standard_icon(out):
    leather = leather_shades(STANDARD["leather"])
    tone = leather["band"] if STANDARD["band"] == "leather" else "#FFFFFF"
    notebook(os.path.join(out, "AppIcon.icon"), leather, STANDARD["ribbon"], (tone, tone), ground_shades(STANDARD["ground"]))

def passes(out):
    """One document per part: that part in grey, the rest black. The app adds them up in linear light."""
    for part in ("base", "ground", "cover", "band", "ribbon"):
        def colour(p): return PASS_GREY if p == part else "#000000"
        ground = (colour("ground"), colour("ground"))
        notebook(os.path.join(out, f"pass-{part}.icon"), colour("cover"), colour("ribbon"),
                 (colour("band"), colour("band")), {"light": ground, "dark": ground})

def leather(out):
    """The grain at half its contrast, lifted so that its highlights just reach white: the website multiplies it
    over the button's colour, at 2x."""
    g = 1 + (grain(256, wrap=True) - 1) * 0.5
    # A high percentile rather than the maximum, so that a few bright outliers don't darken the whole tile.
    g = np.clip(g / np.percentile(g, 99.5), 0, 1)
    Image.fromarray((g * 255).round().astype(np.uint8), "L").save(out, quality=82, method=6)


if __name__ == "__main__":
    what, out = sys.argv[1], sys.argv[2]
    {"icon": standard_icon, "passes": passes, "leather": leather}[what](out)
