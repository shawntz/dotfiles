#!/bin/bash
# Packs the built app into a compressed disk image with an /Applications shortcut and a window
# that looks like the app, ready to notarize and publish. Run with --help for the options.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
    cat <<EOF
Usage: scripts/make-dmg.sh [options]

Makes ShawnsDotfiles-<version>.dmg: a compressed (UDZO) image holding "$APP_BUNDLE_NAME"
and a shortcut to /Applications to drag it onto. Uses only hdiutil.

The window it opens in gets its look from two files in Resources/dmg/: background.tiff, the
picture behind the icons, and DS_Store, where Finder reads the window's size and the icons'
places. scripts/make-dmg-art.sh draws both.

  --app PATH         the app to pack           [APP_PATH, default <output>/$APP_BUNDLE_NAME]
  -o, --output DIR   where the image goes      [OUTPUT_DIR, default build/]
  -h, --help         show this help

The image is signed when the app was signed with a real identity: SIGN_IDENTITY if it is set
(and not "-"), otherwise the certificate that signed the app, picked by its SHA-1 so that a
renewed Developer ID with the same name is not ambiguous. An ad hoc app gives an unsigned image.
Build the app first with scripts/build-app.sh.
EOF
}

OUTPUT_DIR="${OUTPUT_DIR:-$INSTALLER_ROOT/build}"
APP_PATH="${APP_PATH:-}"
# What the layout file is called on its way into the image (see below).
LAYOUT_STAND_IN=".layout"

while [ $# -gt 0 ]; do
    case "$1" in
        --app) [ $# -ge 2 ] || die "$1 needs a value"; APP_PATH="$2"; shift 2 ;;
        -o|--output) [ $# -ge 2 ] || die "$1 needs a value"; OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" "Run scripts/make-dmg.sh --help for the options." ;;
    esac
done

OUTPUT_DIR="$(absolute_path "$OUTPUT_DIR")"
APP_PATH="$(absolute_path "${APP_PATH:-$OUTPUT_DIR/$APP_BUNDLE_NAME}")"
[ -d "$APP_PATH" ] || die "no app at $APP_PATH" "Build it first: scripts/build-app.sh"
codesign --verify --deep --strict "$APP_PATH" 2>/dev/null ||
    die "$APP_PATH is not validly signed" "Rebuild it with scripts/build-app.sh."

VERSION="$(plist_value "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)" ||
    die "cannot read the version from $APP_PATH/Contents/Info.plist"
DMG="$OUTPUT_DIR/ShawnsDotfiles-$VERSION.dmg"

for file in background.tiff DS_Store; do
    [ -s "$DMG_ART_DIR/$file" ] || die "there is no $DMG_ART_DIR/$file" \
        "Draw the disk image's window first: scripts/make-dmg-art.sh"
done
# The layout file places icons by file name and finds the picture by the volume's name. One drawn
# for another app name would leave the window white with the icons wherever Finder drops them.
layout_places "$DMG_ART_DIR/DS_Store" "$APP_BUNDLE_NAME" ||
    die "$DMG_ART_DIR/DS_Store has no place for $APP_BUNDLE_NAME" \
        "It was drawn for an app with another name. Draw it again: scripts/make-dmg-art.sh"

mkdir -p "$OUTPUT_DIR"
WORK="$(mktemp -d "$OUTPUT_DIR/.make-dmg.XXXXXX")"
# The image is mounted at $WORK/volume for a moment. A mount point is on another device than the
# folder it is in, which says whether the image is mounted even when hdiutil was cut short.
volume_mounted() {
    [ -d "$WORK/volume" ] || return 1
    [ "$(stat -f %d "$WORK/volume" 2>/dev/null)" != "$(stat -f %d "$WORK" 2>/dev/null)" ]
}
cleanup() {
    if volume_mounted; then
        hdiutil detach -quiet -force "$WORK/volume" >/dev/null 2>&1 || true
    fi
    # -x keeps rm on one file system. Should the image still be mounted, rm stays out of it.
    rm -rfx "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

# Unmounts the image. Something else can hold a new volume for a moment, so this tries a few times.
detach_volume() {
    local _
    for _ in 1 2 3 4 5; do
        if hdiutil detach -quiet "$WORK/volume" 2>/dev/null; then return 0; fi
        sleep 1
    done
    hdiutil detach -quiet -force "$WORK/volume"
}

# The image is signed with the identity that signed the app, unless SIGN_IDENTITY says otherwise.
AUTHORITY="$(signing_authority "$APP_PATH")"
if [ -n "${SIGN_IDENTITY:-}" ]; then
    resolve_identity
elif [ "$AUTHORITY" = "ad hoc" ] || [ "$AUTHORITY" = "unsigned" ] || [ -z "$AUTHORITY" ]; then
    SIGN_ID="-"
    SIGN_LABEL="ad hoc"
else
    # By the certificate's SHA-1, not its name: codesign refuses a name that two certificates share,
    # as the old and the new Developer ID certificate do after a renewal.
    SIGN_ID="$(signing_certificate_sha1 "$APP_PATH" "$WORK")" ||
        die "could not read the certificate that signed $APP_PATH" \
            "Pick the identity yourself: SIGN_IDENTITY=<SHA-1 from security find-identity -v -p codesigning> scripts/make-dmg.sh"
    SIGN_LABEL="$AUTHORITY"
fi

step "Packing $APP_BUNDLE_NAME $VERSION"
mkdir -p "$WORK/root"
ditto "$APP_PATH" "$WORK/root/$APP_BUNDLE_NAME"
ln -s /Applications "$WORK/root/Applications"
cp "$DMG_ART_DIR/background.tiff" "$WORK/root/$DMG_PICTURE_NAME"
# hdiutil create leaves a file named .DS_Store out of the image. So the layout file goes in under
# another name and gets its own once the image is mounted, which takes no free space on it.
# (hdiutil makehybrid would keep the name, but it marks every file with Finder information, and
# with that the app's signature no longer verifies.)
cp "$DMG_ART_DIR/DS_Store" "$WORK/root/$LAYOUT_STAND_IN"

# -nospotlight, -nobrowse and a mount point inside the work folder keep Spotlight and Finder out.
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$WORK/root" -fs HFS+ -format UDRW \
    -nospotlight -ov "$WORK/writable.dmg" ||
    die "hdiutil could not create the disk image"
mkdir -p "$WORK/volume"
hdiutil attach -quiet -nobrowse -noautoopen -noverify -mountpoint "$WORK/volume" "$WORK/writable.dmg" ||
    die "hdiutil could not mount the new disk image"
mv "$WORK/volume/$LAYOUT_STAND_IN" "$WORK/volume/.DS_Store" ||
    die "could not put Finder's layout file in the disk image"
# macOS starts a log of changes on a volume it can write to. It is no part of the app's image.
# macOS can write it once more as the volume unmounts, so the layout file has a place for it
# under the window, as for the picture.
rm -rf "$WORK/volume/.fseventsd" 2>/dev/null || true
# The app must come out of the image as it went in.
codesign --verify --deep --strict "$WORK/volume/$APP_BUNDLE_NAME" 2>/dev/null ||
    die "the app's signature no longer verifies inside the disk image"
detach_volume || die "hdiutil could not unmount the new disk image"

hdiutil convert "$WORK/writable.dmg" -quiet -format UDZO -imagekey zlib-level=9 -ov -o "$WORK/image.dmg" ||
    die "hdiutil could not compress the disk image"
rm -f "$WORK/writable.dmg"

if is_ad_hoc; then
    note "the app is signed ad hoc, so the disk image is left unsigned"
else
    step "Signing the disk image with $SIGN_LABEL"
    codesign --force --timestamp --sign "$SIGN_ID" "$WORK/image.dmg" ||
        die "could not sign the disk image with $SIGN_LABEL"
    codesign --verify --strict "$WORK/image.dmg" || die "codesign could not verify the signed disk image"
fi

hdiutil verify -quiet "$WORK/image.dmg" || die "hdiutil could not verify the new disk image"
mv -f "$WORK/image.dmg" "$DMG"

info "image:     $DMG"
info "size:      $(file_size "$DMG")"
info "signature: $(signing_authority "$DMG")"
printf '%s\n' "$DMG"
