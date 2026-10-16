#!/bin/bash
# Builds Notebook's app icon (Notebook/AppIcon.icon) and the passes Settings › App Icon colours at runtime
# (Packages/NotebookKit/Sources/NotebookKit/Resources/NotebookIcon). Run it after changing Tools/AppIcon/notebook.py.
#   Tools/AppIcon/make.sh
# Needs Xcode (for Icon Composer's ictool), Python 3 with NumPy and Pillow, and rsvg-convert (brew install librsvg).
set -euo pipefail
cd "$(dirname "$0")/../.."

ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
work=build/app-icon
passes=Packages/NotebookKit/Sources/NotebookKit/Resources/NotebookIcon

python3 -c "import PIL, numpy" 2>/dev/null || { echo "Needs Pillow and NumPy: pip3 install pillow numpy" >&2; exit 1; }
command -v rsvg-convert >/dev/null || { echo "Needs rsvg-convert: brew install librsvg" >&2; exit 1; }

rm -rf Notebook/AppIcon.icon "$work"
mkdir -p "$work" "$passes"
python3 Tools/AppIcon/notebook.py icon Notebook
python3 Tools/AppIcon/notebook.py passes "$work"

# Each pass at 512 px, light and dark, in 8 bits: plenty for the Dock and the preview in Settings.
for part in base ground cover band ribbon; do
  for look in Default Dark; do
    name=$([ $look = Default ] && echo light || echo dark)-$part
    "$ictool" "$work/pass-$part.icon" --export-image --output-file "$work/$name.png" \
      --platform macOS --rendition $look --width 512 --height 512 --scale 1 >/dev/null
    python3 - "$work/$name.png" "$passes/$name.png" <<'EOF'
import sys
from PIL import Image
im = Image.open(sys.argv[1])
Image.open(sys.argv[1]).convert("RGBA").save(sys.argv[2], optimize=True, icc_profile=im.info.get("icc_profile"))
EOF
  done
done
echo "Wrote Notebook/AppIcon.icon and $(ls "$passes" | wc -l | tr -d ' ') passes to $passes"
