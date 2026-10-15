# Lays out the README images from the captures that Tools/readme-images.sh takes.
#   python3 Tools/readme-images/build.py <captures folder>
# Writes Design/screenshots/*.webp and Design/social-preview.png. Every image comes in light and dark; the README
# shows the one that matches the reader's theme.
import glob
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(__file__))
from compose import THEMES, backdrop, place, rounded, scaled, shadow_onto

raw = sys.argv[1]
out = "Design/screenshots"
os.makedirs(out, exist_ok=True)


def webp(img, name):
    img.save(f"{out}/{name}.webp", quality=92, method=6)
    print(f"  {out}/{name}.webp")


def window(name):
    return Image.open(f"{raw}/{name}.png").convert("RGBA")


def crop_card(img, box, theme):
    return rounded(img.crop(box), 24, THEMES[theme]["border"])


# Pixels in the 1280 x 820 window at 2x: the note's column with its margin, below the toolbar.
TYPING_BOX = (500, 104, 2140, 1080)
MATH_BOX = (500, 104, 2140, 960)
# The trip further down, from the plan to the PDF, without what scrolled under the toolbar.
OBJECTS_BOX = (500, 150, 2140, 1400)


def typing_animation(theme):
    """The recorded typing as an animated WebP on the backdrop, trimmed to the motion."""
    video = f"{raw}/typing-{theme}.mov"
    fps, width = 25, 1400
    x0, y0, x1, y1 = TYPING_BOX
    # Where something changes: compare each frame with the one before, small and grey.
    sw, sh = (x1 - x0) // 8, (y1 - y0) // 8
    small = subprocess.run(["ffmpeg", "-v", "error", "-i", video, "-vf",
                            f"fps={fps},crop={x1 - x0}:{y1 - y0}:{x0}:{y0},scale={sw}:{sh},format=gray",
                            "-f", "rawvideo", "-"], capture_output=True, check=True).stdout
    frames = np.frombuffer(small, np.uint8).reshape(-1, sh, sw).astype(int)
    moving = [k for k in range(1, len(frames)) if np.abs(frames[k] - frames[k - 1]).mean() > 0.02]
    if not moving:
        sys.exit(f"The recording {video} shows no typing.")
    start, end = max(0, moving[0] / fps - 0.5), moving[-1] / fps + 0.2

    pad = (110, 90)
    # The backdrop and the card's shadow are the same in every frame: draw them once, then put each frame on top.
    shape = rounded(Image.new("RGBA", (x1 - x0, y1 - y0), (0, 0, 0, 255)), 24)
    base = shadow_onto(backdrop((shape.width + 2 * pad[0], shape.height + 2 * pad[1]), theme).convert("RGBA"),
                       shape, pad, theme)
    with tempfile.TemporaryDirectory() as work:
        subprocess.run(["ffmpeg", "-v", "error", "-ss", str(start), "-to", str(end), "-i", video, "-vf",
                        f"fps={fps},crop={x1 - x0}:{y1 - y0}:{x0}:{y0}", "-pix_fmt", "rgb24", f"{work}/f%04d.png"],
                       check=True)
        paths = []
        for k, path in enumerate(sorted(glob.glob(f"{work}/f*.png"))):
            card = crop_card(Image.open(path).convert("RGBA"), (0, 0, x1 - x0, y1 - y0), theme)
            img = base.copy()
            img.alpha_composite(card, pad)
            img = img.convert("RGB")
            img = img.resize((width, round(img.height * width / img.width)), Image.LANCZOS)
            paths.append(f"{work}/o{k:04d}.png")
            img.save(paths[-1])
        command = ["img2webp", "-loop", "0", "-lossy", "-q", "80", "-m", "6"]
        for path in paths:
            command += ["-d", str(round(1000 / fps)), path]
        command[-2] = "2500"  # the finished line stays a moment before it starts over
        subprocess.run(command + ["-o", f"{out}/typing-{theme}.webp"], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"  {out}/typing-{theme}.webp")


def search(theme):
    """The window with the suggestions menu, which may reach past its right edge."""
    img = window(f"search-{theme}")
    return place(img, theme, (130, 110), 1800 * img.width // 2560)


print("Mac")
for theme in ["dark", "light"]:
    webp(place(window(f"note-{theme}"), theme, (160, 130), 2000), f"hero-{theme}")
    typing_animation(theme)
    webp(place(window(f"blocks-{theme}"), theme, (130, 110), 1800), f"blocks-{theme}")
    webp(place(crop_card(window(f"math-{theme}"), MATH_BOX, theme), theme, (110, 90), 1400, rim=False), f"math-{theme}")
    webp(place(crop_card(window(f"objects-{theme}"), OBJECTS_BOX, theme), theme, (110, 90), 1400, rim=False),
         f"objects-{theme}")
    webp(place(window(f"quicklook-{theme}"), theme, (130, 110), 1800), f"quicklook-{theme}")
    webp(search(theme), f"search-{theme}")

print("Social preview")
S = 2  # drawn at 2x, saved at 1280 x 640
canvas = backdrop((1280 * S, 640 * S), "dark").convert("RGBA")
mac = scaled(window("note-dark"), 0.62)
canvas = shadow_onto(canvas, mac, (600 * S, 150 * S), "dark", rim=True)
icon = Image.open("Design/icon.png").convert("RGBA")
canvas.alpha_composite(icon.resize((176 * S, 176 * S), Image.LANCZOS), (66 * S, 128 * S))


def font(weight, size):
    f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size * S)
    f.set_variation_by_name(weight)
    return f


d = ImageDraw.Draw(canvas)
d.text((86 * S, 318 * S), "Notebook", font=font("Bold", 84), fill=(240, 240, 242))
d.text((88 * S, 422 * S), "Your notes as Markdown files,", font=font("Medium", 32), fill=(206, 205, 210))
d.text((88 * S, 462 * S), "native on the Mac.", font=font("Medium", 32), fill=(206, 205, 210))
d.text((88 * S, 530 * S), "Written like in Notes, kept in", font=font("Regular", 22), fill=(146, 145, 152))
d.text((88 * S, 560 * S), "your own folders.", font=font("Regular", 22), fill=(146, 145, 152))
canvas.convert("RGB").resize((1280, 640), Image.LANCZOS).save("Design/social-preview.png", optimize=True)
print("  Design/social-preview.png")
