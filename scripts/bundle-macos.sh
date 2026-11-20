#!/bin/sh
# Builds build/Alloy.app from a release build: the executable, MetalUI's
# resource bundles (shaders, highlight queries) in Contents/Resources, an .icns when
# Packaging/icon-1024.png exists, any Contents/Frameworks/*.framework signed
# inside-out. The steps are MetalUI's docs/packaging.md.
#
# Usage: scripts/bundle-macos.sh [--version X.Y.Z] [--build N]
#   --version  CFBundleShortVersionString (default: the value in Info.plist)
#   --build    CFBundleVersion, a monotonically increasing integer
#
# Signing: with ALLOY_SIGN_IDENTITY set (CODESIGN_IDENTITY is accepted as a
# fallback) the app is signed with the hardened runtime, a secure timestamp and
# Packaging/macOS/Alloy.entitlements; otherwise it is signed ad hoc.
#
# Sparkle: ALLOY_SPARKLE_PUBLIC_KEY (the base64 EdDSA public key printed by Sparkle's
# generate_keys) replaces the SUPublicEDKey placeholder in Info.plist. It is required
# when signing with an identity (a release build); without it the key is removed from
# the bundled plist. Identity-signed builds also get AlloyReleaseBuild=YES, which makes the app
# ignore the ALLOY_UPDATE_FEED_URL test-feed override.
set -eu
cd "$(dirname "$0")/.."

VERSION=""
BUILD=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version) [ $# -ge 2 ] || { echo "error: --version needs a value" >&2; exit 2; }; VERSION=$2; shift 2 ;;
        --build) [ $# -ge 2 ] || { echo "error: --build needs a value" >&2; exit 2; }; BUILD=$2; shift 2 ;;
        *) echo "usage: $0 [--version X.Y.Z] [--build N]" >&2; exit 2 ;;
    esac
done
if [ -n "$VERSION" ]; then
    echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "error: --version must look like 1.2.3" >&2; exit 2; }
fi
if [ -n "$BUILD" ]; then
    echo "$BUILD" | grep -Eq '^[0-9]+$' || { echo "error: --build must be an integer" >&2; exit 2; }
fi

NAME=Alloy
IDENTITY="${ALLOY_SIGN_IDENTITY:-${CODESIGN_IDENTITY:-}}"
SPARKLE_KEY="${ALLOY_SPARKLE_PUBLIC_KEY:-}"
if [ -n "$IDENTITY" ] && [ -z "$SPARKLE_KEY" ]; then
    echo "error: ALLOY_SPARKLE_PUBLIC_KEY is not set; a release build needs the Sparkle EdDSA public key (run Sparkle's generate_keys)" >&2
    exit 1
fi
swift build -c release --arch arm64 --product "$NAME"
BIN=$(swift build -c release --arch arm64 --product "$NAME" --show-bin-path)
APP="build/$NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/$NAME" "$APP/Contents/MacOS/"

# The linker leaves absolute build-machine paths (the Xcode toolchain, the build directory) as LC_RPATH entries.
# They are useless in a shipped app and leak local paths, so they are deleted; @executable_path and @loader_path
# entries stay. Idempotent: with nothing to delete it does nothing and succeeds.
# BEGIN strip_build_rpaths
strip_build_rpaths() {
    rpath_list=$(otool -l "$1" | awk '$1 == "cmd" && $2 == "LC_RPATH" { want = 1 } want && $1 == "path" { print $2; want = 0 }')
    while IFS= read -r rp; do
        case "$rp" in
            /Applications/*|/Library/Developer/*|/var/run/*|/Users/*) install_name_tool -delete_rpath "$rp" "$1" ;;
        esac
    done <<RPATHS
$rpath_list
RPATHS
}
# END strip_build_rpaths
strip_build_rpaths "$APP/Contents/MacOS/$NAME"

# Licence of Alloy itself and the third-party notices (the Acknowledgements menu item opens the latter).
for f in LICENSE THIRD-PARTY-NOTICES.md; do
    [ -f "$f" ] || { echo "bundle-macos: $f is missing" >&2; exit 1; }
    cp "$f" "$APP/Contents/Resources/"
done
# Every SwiftPM resource bundle the app links (MetalUI's shaders, the tree-sitter highlight queries), not the test bundles.
for b in "$BIN"/*.bundle; do
    case "$(basename "$b")" in *Tests.bundle) continue ;; esac
    cp -R "$b" "$APP/Contents/Resources/"
done
test -f "$APP/Contents/Resources/TreeSitterRust_TreeSitterRust.bundle/Contents/Resources/queries/highlights.scm" \
    || { echo "bundle-macos: highlight queries missing from $APP" >&2; exit 1; }
cp Packaging/macOS/Info.plist "$APP/Contents/Info.plist"
# Embed frameworks the build produced next to the executable (Sparkle.framework).
for fw in "$BIN"/*.framework; do
    [ -d "$fw" ] || continue
    mkdir -p "$APP/Contents/Frameworks"
    cp -R "$fw" "$APP/Contents/Frameworks/"
done
# Without a key (dev / ad hoc builds) the key is removed rather than shipping the invalid placeholder.
if [ -n "$SPARKLE_KEY" ]; then
    plutil -replace SUPublicEDKey -string "$SPARKLE_KEY" "$APP/Contents/Info.plist"
else
    plutil -remove SUPublicEDKey "$APP/Contents/Info.plist"
fi
# Identity-signed builds are release builds: this flag makes the app ignore ALLOY_UPDATE_FEED_URL.
if [ -n "$IDENTITY" ]; then
    plutil -insert AlloyReleaseBuild -bool YES "$APP/Contents/Info.plist"
fi
[ -z "$VERSION" ] || plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
[ -z "$BUILD" ] || plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"

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

if [ -n "$IDENTITY" ]; then
    # Hardened runtime + secure timestamp (both required for notarisation).
    sign() { codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@"; }
    sign_app() { sign --entitlements Packaging/macOS/Alloy.entitlements "$@"; }
else
    sign() { codesign --force --sign - "$@"; }
    sign_app() { sign "$@"; }
fi

# Frameworks (Sparkle) are signed inside-out: nested helpers and XPC services
# first, then the framework, then the app. No --deep.
if [ -d "$APP/Contents/Frameworks" ]; then
    for fw in "$APP"/Contents/Frameworks/*.framework; do
        [ -d "$fw" ] || continue
        # Lists are captured first and looped over without a pipe: `sh` has no pipefail, and a pipe would
        # hide a failing codesign. Any signing failure stops the script.
        nested_list=$(find "$fw" -type d \( -name '*.xpc' -o -name '*.app' \) -prune -print | awk '{ print length($0) " " $0 }' | sort -rn | cut -d' ' -f2-)
        while IFS= read -r nested; do
            [ -n "$nested" ] || continue
            sign --preserve-metadata=entitlements "$nested" || { echo "error: codesign failed for $nested" >&2; exit 1; }
        done <<EOF
$nested_list
EOF
        exe_list=$(cd "$fw" && find Versions -maxdepth 2 -type f -perm -u+x ! -path '*.xpc/*' ! -path '*.app/*')
        while IFS= read -r exe; do
            [ -n "$exe" ] || continue
            sign "$fw/$exe" || { echo "error: codesign failed for $fw/$exe" >&2; exit 1; }
        done <<EOF
$exe_list
EOF
        sign "$fw" || { echo "error: codesign failed for $fw" >&2; exit 1; }
    done
fi

sign_app "$APP" || { echo "error: codesign failed for $APP" >&2; exit 1; }
codesign --verify --strict --deep "$APP"
echo "$APP"
