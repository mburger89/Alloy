#!/bin/sh
# Builds build/Alloy.app from a release build: the executable, MetalUI's
# shader resources in Contents/Resources, an .icns when
# Packaging/icon-1024.png exists, signed ad hoc unless CODESIGN_IDENTITY is
# set. The steps are MetalUI's docs/packaging.md.
set -eu
cd "$(dirname "$0")/.."

NAME=Alloy
swift build -c release --product "$NAME"
BIN=$(swift build -c release --product "$NAME" --show-bin-path)
APP="build/$NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/$NAME" "$APP/Contents/MacOS/"
cp -R "$BIN/MetalUI_MetalUIRender.bundle" "$APP/Contents/Resources/"
cp Packaging/macOS/Info.plist "$APP/Contents/Info.plist"

if [ -f Packaging/icon-1024.png ]; then
    ICONSET="$(mktemp -d)/$NAME.iconset"
    mkdir -p "$ICONSET"
    for n in 16 32 128 256 512; do
        sips -z $n $n Packaging/icon-1024.png --out "$ICONSET/icon_${n}x${n}.png" >/dev/null
        sips -z $((n * 2)) $((n * 2)) Packaging/icon-1024.png --out "$ICONSET/icon_${n}x${n}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/$NAME.icns"
fi

plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
echo "$APP"
