#!/usr/bin/env bash
# Cuts a notarised Alloy release locally.
#
# Usage: scripts/release-macos.sh <version> [--dry-run | --appcast-only]
#
# Env (required unless --dry-run):
#   ALLOY_SIGN_IDENTITY   Developer ID Application identity name
#   ALLOY_NOTARY_PROFILE  notarytool keychain profile name
#   ALLOY_SPARKLE_PUBLIC_KEY  Sparkle EdDSA public key (embedded as SUPublicEDKey by the bundler)
# Optional:
#   ALLOY_SPARKLE_BIN     directory holding Sparkle's generate_appcast. Default: the binary
#                         artifact SwiftPM resolved, .build/artifacts/sparkle/Sparkle/bin
#                         (created by `swift build` or `swift package resolve`; the version is
#                         pinned in Package.swift). The EdDSA private key is never passed on a
#                         command line: generate_appcast reads it from the login keychain.
#
# Steps: preconditions, bundle (scripts/bundle-macos.sh), notarise + staple the app,
# build + sign + notarise + staple Alloy.dmg, verify (including the app inside the
# finished DMG), write build/release/<version>/ (Alloy.dmg and Alloy-<version>.dmg,
# same bytes), then ask `Publish v<version>? [y/N]` and on y create the GitHub Release.
#
# Public-sync marker: tools/publish-public.sh writes the published source SHA to
# <main checkout>/.superpowers/public-sync-state; that must equal HEAD.
# No local tag is made: `gh release create --target main` creates v<version> on the
# public repo, at the snapshot the sync published. A failed upload deletes the partial
# release (it is known not to have existed before), so the script can simply be rerun.
#
# After the release is public, the appcast step runs Sparkle's generate_appcast over
# Alloy-<version>.dmg (release notes: docs/releases/<version>.md, embedded as Markdown) and
# updates Bench/site/appcast.xml, keeping earlier entries. Commit and publish the site
# afterwards. If that step fails the release itself is already public: fix the cause and run
# `scripts/release-macos.sh <version> --appcast-only`, which only redoes the appcast from the
# kept build/release/<version>/ artefacts and is safe to repeat.
#
# --dry-run signs ad hoc, skips the environment, git-state and notarisation steps,
# and never publishes.
set -euo pipefail

REPO_SLUG="mburger89/Alloy"
VOLUMES_DIR="${ALLOY_VOLUMES_DIR:-/Volumes}"
VERSION=""
DRY=0
APPCAST_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        --appcast-only) APPCAST_ONLY=1 ;;
        -h|--help) sed -n '2,/^set /{/^#/s/^# \{0,1\}//p;}' "$0"; exit 0 ;;
        -*) echo "error: unknown option $arg" >&2; exit 2 ;;
        *) [ -z "$VERSION" ] || { echo "error: more than one version given" >&2; exit 2; }; VERSION=$arg ;;
    esac
done
[ -n "$VERSION" ] || { echo "usage: $0 <version> [--dry-run | --appcast-only]" >&2; exit 2; }
[ "$DRY$APPCAST_ONLY" != 11 ] || { echo "error: --dry-run and --appcast-only exclude each other" >&2; exit 2; }
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "error: version must look like 1.2.3" >&2; exit 2; }

cd "$(dirname "$0")/.."
ROOT=$PWD
TAG="v$VERSION"
NOTES="docs/releases/$VERSION.md"

die() { echo "ERROR: $*" >&2; exit 1; }
# step <name> <command...>: run, naming the step if it fails. Note that errexit is off
# inside functions run this way, so such functions must check every command themselves.
step() { local name=$1; shift; echo "==> $name"; "$@" || die "step '$name' failed"; }

# Cleanup on any exit, interrupt or termination: detach images, remove scratch files.
SCRATCH=""
MOUNTS=""
CONFIRMED_ABSENT=0
# 1 while `gh release create` runs: an interrupt then may leave a partial release behind.
RELEASE_IN_FLIGHT=0
DELETE_HINT="gh release delete $TAG -R $REPO_SLUG --cleanup-tag"

# detach_retry <mountpoint>: Finder and Spotlight often hold a freshly laid-out volume for a few
# seconds ("Resource busy"), so retry with a pause, then force as a last resort.
# ALLOY_DETACH_DELAY (seconds between tries, default 2) is a test hook.
detach_retry() {
    local i delay="${ALLOY_DETACH_DELAY:-2}"
    for i in 1 2 3 4 5; do
        hdiutil detach "$1" && return 0
        [ "$i" = 5 ] || sleep "$delay"
    done
    echo "warning: $1 stayed busy; forcing the detach" >&2
    hdiutil detach "$1" -force
}

cleanup() {
    local m
    if [ "$RELEASE_IN_FLIGHT" = 1 ]; then
        echo "" >&2
        echo "INTERRUPTED during 'gh release create': a partial release for $TAG may exist on $REPO_SLUG." >&2
        echo "Check it, and remove it before rerunning with: $DELETE_HINT" >&2
    fi
    while IFS= read -r m; do
        [ -z "$m" ] || detach_retry "$m" >/dev/null 2>&1 || true
    done <<< "$MOUNTS"
    [ -z "$SCRATCH" ] || rm -rf "$SCRATCH"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# find_generate_appcast: sets GENERATE_APPCAST to Sparkle's tool (see the header).
find_generate_appcast() {
    local dir="${ALLOY_SPARKLE_BIN:-$ROOT/.build/artifacts/sparkle/Sparkle/bin}"
    GENERATE_APPCAST="$dir/generate_appcast"
    GENERATE_KEYS="$dir/generate_keys"
    [ -x "$GENERATE_APPCAST" ] || die "generate_appcast not found at $GENERATE_APPCAST; run 'swift package resolve' or set ALLOY_SPARKLE_BIN to Sparkle's bin directory"
}

# check_sparkle_key: ALLOY_SPARKLE_PUBLIC_KEY must be the public half of the EdDSA key in the
# login keychain; otherwise every build shipped from here could never update.
check_sparkle_key() {
    [ -x "$GENERATE_KEYS" ] || die "generate_keys not found at $GENERATE_KEYS"
    local keychain_pub rc=0
    keychain_pub=$("$GENERATE_KEYS" -p 2>/dev/null) || rc=$?
    keychain_pub=$(printf '%s' "$keychain_pub" | tr -d '[:space:]')
    if [ "$rc" -ne 0 ] || [ -z "$keychain_pub" ]; then
        die "no Sparkle EdDSA key in the login keychain (generate_keys -p failed); run generate_keys and set ALLOY_SPARKLE_PUBLIC_KEY to its public key"
    fi
    [ "$keychain_pub" = "$ALLOY_SPARKLE_PUBLIC_KEY" ] || die "ALLOY_SPARKLE_PUBLIC_KEY does not match the keychain's Sparkle public key; releases signed with the keychain key could not be verified by this build"
}

# appcast_step: add this version's DMG to Bench/site/appcast.xml. Works in a scratch
# directory seeded with the current feed (so earlier entries survive) and installs the
# result only on success, so a failed or repeated run never corrupts the feed.
appcast_step() {
    local dmg="$ROOT/$OUT/Alloy-$VERSION.dmg" feed="$ROOT/Bench/site/appcast.xml" work="$SCRATCH/appcast"
    [ -f "$dmg" ] || { echo "$dmg not found" >&2; return 1; }
    mkdir -p "$work" "$(dirname "$feed")" || return 1
    cp "$dmg" "$work/" || return 1
    # generate_appcast embeds a same-named .md file as Markdown release notes.
    cp "$NOTES" "$work/Alloy-$VERSION.md" || return 1
    if [ -f "$feed" ]; then cp "$feed" "$work/appcast.xml" || return 1; fi
    # No key material here: generate_appcast reads the EdDSA key from the login keychain.
    "$GENERATE_APPCAST" --download-url-prefix "https://github.com/$REPO_SLUG/releases/download/$TAG/" \
        --embed-release-notes --maximum-versions 0 --link "https://mburger89.github.io/Alloy/" \
        -o "$work/appcast.xml" "$work" || return 1
    [ -s "$work/appcast.xml" ] || { echo "generate_appcast produced no appcast" >&2; return 1; }
    cp "$work/appcast.xml" "$feed" || return 1
    echo "Updated $feed; commit it and publish the site"
}

OUT="build/release/$VERSION"
if [ "$APPCAST_ONLY" = 1 ]; then
    [ -f "$NOTES" ] || die "release notes $NOTES not found"
    find_generate_appcast
    [ -n "${ALLOY_SPARKLE_PUBLIC_KEY:-}" ] || die "ALLOY_SPARKLE_PUBLIC_KEY is not set (Sparkle EdDSA public key)"
    check_sparkle_key
    SCRATCH=$(mktemp -d)
    step "appcast" appcast_step
    exit 0
fi

# 1. Preconditions: nothing external happens before these pass.
[ -f "$NOTES" ] || die "release notes $NOTES not found; write them first"
if [ "$DRY" = 0 ]; then
    ! grep -q '<!-- PLACEHOLDER -->' "$NOTES" || die "$NOTES still contains the <!-- PLACEHOLDER --> marker; write the real notes first"
    [ -n "${ALLOY_SIGN_IDENTITY:-}" ] || die "ALLOY_SIGN_IDENTITY is not set (Developer ID Application identity name)"
    [ -n "${ALLOY_NOTARY_PROFILE:-}" ] || die "ALLOY_NOTARY_PROFILE is not set (notarytool keychain profile name)"
    [ -n "${ALLOY_SPARKLE_PUBLIC_KEY:-}" ] || die "ALLOY_SPARKLE_PUBLIC_KEY is not set (Sparkle EdDSA public key)"
    find_generate_appcast
    [ -z "$(git status --porcelain)" ] || die "working tree is not clean"
    [ "$(git rev-parse --abbrev-ref HEAD)" = "master" ] || die "current branch is not master"
    git fetch -q origin || die "git fetch origin failed"
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "master != origin/main; push first"
    MAIN_REPO="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
    STATE_FILE="$MAIN_REPO/.superpowers/public-sync-state"
    if [ ! -f "$STATE_FILE" ] || [ "$(tr -d '[:space:]' < "$STATE_FILE")" != "$(git rev-parse HEAD)" ]; then
        die "the public sync marker ($STATE_FILE) does not match HEAD $(git rev-parse --short HEAD).
Run tools/publish-public.sh first. If it already said 'public is already up to date', it
exited without refreshing the marker: write HEAD's SHA to the marker file after checking
that the public repo really holds this snapshot."
    fi
    # Read-only external checks. "Not found" must be positively confirmed (HTTP 404);
    # any other error (network, auth, rate limit) stops the script before anything external.
    gh_missing() { # gh_missing <what> <api path>: 0 only if the API answers 404
        local out rc=0
        out=$(gh api "$2" 2>&1) || rc=$?
        if [ "$rc" -eq 0 ]; then die "$1 $TAG already exists on $REPO_SLUG. If it is a partial release left by an interrupted run, remove it with: $DELETE_HINT"; fi
        case "$out" in *"HTTP 404"*) return 0 ;; esac
        die "could not check whether $1 $TAG exists on $REPO_SLUG (not a 404): $out"
    }
    gh_missing "release" "repos/$REPO_SLUG/releases/tags/$TAG"
    gh_missing "tag" "repos/$REPO_SLUG/git/ref/tags/$TAG"
    # Draft releases do not answer the by-tag lookup; the list includes them.
    listing=$(gh api --paginate "repos/$REPO_SLUG/releases" --jq '.[].tag_name') \
        || die "could not list releases of $REPO_SLUG"
    # A here-string, not a pipe: under pipefail grep -q closing the pipe early would make printf fail and hide the match.
    ! grep -Fxq "$TAG" <<< "$listing" || die "a (draft) release for $TAG already exists on $REPO_SLUG. If it is a partial release left by an interrupted run, remove it with: $DELETE_HINT"
    check_sparkle_key
    CONFIRMED_ABSENT=1
    IDENTITY=$ALLOY_SIGN_IDENTITY
else
    echo "NOTE: --dry-run: ad hoc signing, no notarisation, no git-state checks, no publishing"
    IDENTITY=-
fi
[ ! -e "$VOLUMES_DIR/Alloy" ] || die "a volume named Alloy is mounted at $VOLUMES_DIR/Alloy; eject it first"

BUILD_NUMBER=$(git rev-list --count HEAD)
APP="build/Alloy.app"
DMG="$OUT/Alloy.dmg"
rm -rf "$OUT"
mkdir -p "$OUT"
SCRATCH=$(mktemp -d)

# 2. Bundle (Task 1). Dry-run must sign ad hoc even if an identity is exported.
if [ "$DRY" = 1 ]; then
    step "bundle" env -u ALLOY_SIGN_IDENTITY -u CODESIGN_IDENTITY scripts/bundle-macos.sh --version "$VERSION" --build "$BUILD_NUMBER"
else
    step "bundle" scripts/bundle-macos.sh --version "$VERSION" --build "$BUILD_NUMBER"
fi
[ -d "$APP" ] || die "step 'bundle' failed: $APP missing"

# json_field <key>: reads JSON on stdin.
json_field() { plutil -extract "$1" raw -o - - 2>/dev/null; }

# notarize <file>: submit and wait; only status Accepted passes (notarytool can exit 0
# for an Invalid result). On failure the notary log is printed.
notarize() {
    local json rc=0 status id
    json=$(xcrun notarytool submit "$1" --keychain-profile "$ALLOY_NOTARY_PROFILE" --wait --output-format json) || rc=$?
    echo "$json"
    status=$(printf '%s' "$json" | json_field status) || status=""
    id=$(printf '%s' "$json" | json_field id) || id=""
    if [ "$rc" -eq 0 ] && [ "$status" = "Accepted" ]; then return 0; fi
    echo "notarisation failed (exit $rc, status '${status:-unknown}')" >&2
    if [ -n "$id" ]; then xcrun notarytool log "$id" --keychain-profile "$ALLOY_NOTARY_PROFILE" >&2 || true; fi
    return 1
}

# 3. Notarise and staple the app.
if [ "$DRY" = 0 ]; then
    step "zip app" ditto -c -k --keepParent "$APP" "$SCRATCH/Alloy-app.zip"
    step "notarise app" notarize "$SCRATCH/Alloy-app.zip"
    step "staple app" xcrun stapler staple "$APP"
fi

# attach/detach keep MOUNTS current so the exit trap can detach whatever is left.
attach() { # attach <mountpoint> <hdiutil attach args...>
    local mnt=$1; shift
    hdiutil attach "$@" -mountpoint "$mnt" -noverify || return 1
    MOUNTS+="$mnt"$'\n'
}
detach() {
    detach_retry "$1" || return 1
    MOUNTS=${MOUNTS//"$1"$'\n'/}
}

# 4. DMG: app + Applications link, laid out with Packaging/macOS/dmg. Every command is
# checked explicitly (see `step`).
make_dmg() {
    local stage="$SCRATCH/dmg" rw="$SCRATCH/rw.dmg" mnt="$VOLUMES_DIR/Alloy"
    mkdir -p "$stage/.background" || return 1
    cp -R "$APP" "$stage/Alloy.app" || return 1
    ln -s /Applications "$stage/Applications" || return 1
    cp Packaging/macOS/dmg/background.png "$stage/.background/background.png" || return 1
    hdiutil create -volname Alloy -srcfolder "$stage" -fs HFS+ -format UDRW -ov "$rw" || return 1
    # Mounted visibly (no -nobrowse): Finder must see the volume to apply the layout.
    attach "$mnt" "$rw" || return 1
    osascript Packaging/macOS/dmg/layout.applescript Alloy || echo "warning: DMG window layout was not applied" >&2
    # The app and the Applications link are required; the window cosmetics are not.
    [ -d "$mnt/Alloy.app" ] || { echo "image has no Alloy.app" >&2; return 1; }
    [ "$(readlink "$mnt/Applications")" = "/Applications" ] || { echo "image has no Applications link" >&2; return 1; }
    sync
    detach "$mnt" || return 1
    hdiutil convert "$rw" -format UDZO -imagekey zlib-level=9 -ov -o "$ROOT/$DMG" || return 1
}
step "build dmg" make_dmg
if [ "$IDENTITY" = "-" ]; then
    step "sign dmg" codesign --force --sign - "$DMG"
else
    step "sign dmg" codesign --force --sign "$IDENTITY" --timestamp "$DMG"
fi
if [ "$DRY" = 0 ]; then
    step "notarise dmg" notarize "$DMG"
    step "staple dmg" xcrun stapler staple "$DMG"
    step "verify dmg (spctl)" spctl -a -t open --context context:primary-signature -vv "$DMG"
fi
step "verify dmg signature" codesign --verify --deep --strict "$DMG"

# The app inside the finished DMG is what users get: verify that one.
verify_dmg_app() {
    local vm="$SCRATCH/verify" rc=0
    mkdir -p "$vm" || return 1
    attach "$vm" "$ROOT/$DMG" -readonly -nobrowse || return 1
    codesign --verify --deep --strict "$vm/Alloy.app" || rc=1
    if [ "$DRY" = 0 ]; then
        spctl -a -t exec -vv "$vm/Alloy.app" || rc=1
        xcrun stapler validate "$vm/Alloy.app" || rc=1
    fi
    detach "$vm" || return 1
    return $rc
}
step "verify app inside dmg" verify_dmg_app

# 5. Release artefacts: same bytes under the stable and the versioned name.
step "versioned copy" cp "$DMG" "$OUT/Alloy-$VERSION.dmg"
echo "Release artefacts in $OUT"

if [ "$DRY" = 1 ]; then
    echo "--dry-run: done, nothing published"
    exit 0
fi

# 6. Confirm and publish.
printf 'Publish %s? [y/N] ' "$TAG"
answer=""
read -r answer || true
case "$answer" in
    y|Y) ;;
    *) echo "Not published (artefacts kept in $OUT)"; exit 0 ;;
esac

echo "==> gh release create"
RELEASE_IN_FLIGHT=1
if ! gh release create "$TAG" -R "$REPO_SLUG" --target main --latest --title "Alloy $VERSION" \
        --notes-file "$NOTES" "$OUT/Alloy.dmg" "$OUT/Alloy-$VERSION.dmg"; then
    # Only a release this run could have created (tag and release confirmed absent
    # beforehand) is cleaned up; anything else is left alone.
    cleaned=0
    if [ "$CONFIRMED_ABSENT" = 1 ]; then
        if gh release delete "$TAG" -R "$REPO_SLUG" --cleanup-tag --yes >/dev/null 2>&1; then cleaned=1; fi
    fi
    RELEASE_IN_FLIGHT=0
    if [ "$cleaned" = 1 ]; then die "step 'gh release create' failed; partial release removed, rerun to retry"; fi
    die "step 'gh release create' failed and a partial release may remain. Check it and remove it with: $DELETE_HINT"
fi
RELEASE_IN_FLIGHT=0
# The release is public from here on: a failure below must be fixed and retried with
# --appcast-only (the release cannot be recreated).
echo "==> appcast"
appcast_step || die "the release $TAG is PUBLIC but the appcast step failed; fix the cause and run: scripts/release-macos.sh $VERSION --appcast-only"
echo "Published $TAG"
