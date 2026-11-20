#!/bin/bash
# Regenerates background@2x.png and background.tiff from background.png (the 600x400 art).
# There is no separate 2x source: the 2x picture is the 1x scaled to 1200x800 at 144 dpi, and
# the TIFF holds both so Finder picks the right one on Retina and standard displays.
# Usage: Packaging/macOS/dmg/make-background.sh
set -euo pipefail
cd "$(dirname "$0")"
sips --resampleHeightWidth 800 1200 -s dpiWidth 144 -s dpiHeight 144 background.png --out background@2x.png >/dev/null
tiffutil -cathidpicheck background.png background@2x.png -out background.tiff
