#!/bin/bash
# Takes the README's pictures of the Mac app on the sample notes and lays them out as Design/screenshots/*.webp and
# Design/social-preview.png.
#   Tools/readme-images.sh
# The app runs in the background on a fresh copy of the sample notes (Debug/DemoLibrary.swift), under a bundle
# identifier of its own so your Folio's settings stay as they are. It never comes to the front and leaves keyboard and
# mouse alone; only the search suggestions show on screen for a moment. Takes about a minute and a half. Needs Screen
# Recording permission for the terminal, a Retina display, Python 3 with Pillow and NumPy, ffmpeg and img2webp
# (brew install ffmpeg webp).
set -euo pipefail
cd "$(dirname "$0")/.."

work=build/readme-images
raw=$work/raw
library=$work/Notes
app=$work/DerivedData/Build/Products/Debug/Folio.app
bundle_id=com.lukaskbl.Folio.readme

python3 -c "import PIL, numpy" 2>/dev/null || { echo "Needs Pillow and NumPy: pip3 install pillow numpy" >&2; exit 1; }
for tool in ffmpeg img2webp; do
  command -v $tool >/dev/null || { echo "Needs $tool: brew install ffmpeg webp" >&2; exit 1; }
done

echo "Building…"
xcodebuild -project Folio.xcodeproj -scheme Folio -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$work/DerivedData" PRODUCT_BUNDLE_IDENTIFIER=$bundle_id build -quiet
mkdir -p "$raw"
swiftc -O Tools/readme-images/capture.swift -o "$work/capture" 2>/dev/null

pid=""
finish() {
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
}
trap finish EXIT

# say <command>…: drives the app through its debug remote (Debug/DebugRemote.swift).
say() { for line in "$@"; do echo "$line" >> "$work/cmd"; done; }

# shot <name>: the window, without anything in front of or behind it.
shot() { "$work/capture" shot "$pid" "$raw/$1.png" > /dev/null; }

launch() {
  # Fresh notes and settings every time: the typing scene changes a note, and the sidebar remembers what was open.
  rm -rf "${library:?}"
  defaults delete $bundle_id 2>/dev/null || true
  : > "$work/cmd"
  rm -f "$work/cmd.log"
  open -n -g "$app" --args -FolioLibrary "$PWD/$library" -FolioLibraryName "iCloud Drive" -FolioDemo YES \
    -AppleLanguages '(en)' -AppleLocale en_US -NSAllowContinuousSpellChecking NO -FolioTips hide -debugCommandFile "$PWD/$work/cmd" \
    "-NSWindow Frame main" "160 80 1280 820 0 0 1512 949"
  for _ in $(seq 40); do
    pid=$(pgrep -nf "$PWD/$app/Contents/MacOS" || true)
    [ -n "$pid" ] && break
    sleep 0.25
  done
  [ -n "$pid" ] || { echo "The app didn't start." >&2; exit 1; }
  for _ in $(seq 40); do
    say "open Travel/Kyoto trip.md" "dump"
    sleep 0.5
    grep -q "Kyoto trip.md" "$work/cmd.log" 2>/dev/null && return 0
  done
  echo "The app didn't open the sample notes." >&2
  exit 1
}

# typing <seconds>: the commands that type a few lines at the end of "Weekend", a key at a time.
typing() {
  python3 - "$library/Personal/Weekend.md" <<'EOF'
import sys
text = open(sys.argv[1], encoding="utf-8").read().rstrip("\n")
end = len(text.encode("utf-16-le")) // 2
lines = [f"caret {end}", "showcaret 1", "wait 0.8"]
def typed(s, delay=0.07):
    for ch in s:
        lines.extend(["key return" if ch == "\n" else f"type {ch}", f"wait {delay}"])
typed("\n\n## Sunday")
lines.append("wait 0.5")
typed("\n- [ ] A long walk by the **lake**")
lines.append("wait 0.6")
typed(", then ==coffee== at Mia's")
print("\n".join(lines))
EOF
}

for theme in dark light; do
  echo "Scenes in ${theme}…"
  launch
  say "appearance $theme"
  sleep 1.5
  shot "note-$theme"

  say "open Projects/Folio roadmap.md"; sleep 1.5; shot "blocks-$theme"
  say "open University/Linear algebra/Week 3.md"; sleep 1.5; shot "math-$theme"
  say "open Travel/Flight tickets.pdf"; sleep 2; shot "quicklook-$theme"
  # Further down the trip: the plan with its link, the callout, the table and the embedded PDF.
  say "open Travel/Kyoto trip.md"; sleep 1.2; say "scroll 640"; sleep 1; shot "objects-$theme"

  say "open Personal/Weekend.md"; sleep 1.5
  rm -f "$raw/typing-$theme.mov"
  "$work/capture" rec "$pid" "$raw/typing-$theme.mov" 11 > "$work/rec.log" &
  recorder=$!
  for _ in $(seq 40); do grep -q recording "$work/rec.log" 2>/dev/null && break; sleep 0.1; done
  typing >> "$work/cmd"
  wait $recorder
  say "showcaret 0"

  # Last, since the suggestions menu shows on screen even though the app is in the background.
  say "palette" "wait 0.4" "type kyoto"; sleep 2
  "$work/capture" all "$pid" "$raw/search-$theme.png" > "$raw/search-$theme.txt"
  say "key escape"

  kill "$pid"
  pid=""
  sleep 1
done

size=$(sips -g pixelWidth -g pixelHeight "$raw/note-dark.png" | awk '/pixel/ { printf "%s ", $2 }')
if [ "$size" != "2560 1640 " ]; then
  echo "The window came out ${size% }px; the layout expects 1280 x 820 points on a Retina display." >&2
  exit 1
fi

echo "Laying out…"
python3 Tools/readme-images/build.py "$raw"
echo "Done. Check the images, then commit them with the change they show."
