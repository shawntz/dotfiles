#!/bin/bash
# Packs the built app into a compressed disk image with an /Applications shortcut, ready to
# notarize and publish. Run with --help for the options.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
    cat <<EOF
Usage: scripts/make-dmg.sh [options]

Makes ShawnsDotfiles-<version>.dmg: a compressed (UDZO) image holding "$APP_BUNDLE_NAME"
and a shortcut to /Applications to drag it onto. Uses only hdiutil.

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

mkdir -p "$OUTPUT_DIR"
WORK="$(mktemp -d "$OUTPUT_DIR/.make-dmg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

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

# -nospotlight and the hidden temporary mount keep Finder and Spotlight out of it.
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$WORK/root" -fs HFS+ -format UDZO \
    -imagekey zlib-level=9 -nospotlight -ov "$WORK/image.dmg" ||
    die "hdiutil could not create the disk image"

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
