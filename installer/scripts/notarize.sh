#!/bin/bash
# Sends a signed disk image (or app) to Apple's notary service, waits for the verdict and staples
# the ticket. Run with --help for the options.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
    cat <<EOF
Usage: NOTARY_PROFILE=<profile> scripts/notarize.sh [FILE]

Notarizes FILE (a .dmg or a .app) with 'xcrun notarytool submit --wait', then staples the
ticket with 'xcrun stapler staple' so Gatekeeper accepts it offline.

Without FILE it notarizes build/ShawnsDotfiles-<version>.dmg, the output of 'make dmg'. The
disk image 'make release' builds is another file: pass it, as release.sh's summary shows:
  scripts/notarize.sh build/release/<version>/ShawnsDotfiles-<version>.dmg

FILE must be signed with a Developer ID Application identity; ad hoc builds are refused
before anything is uploaded.

NOTARY_PROFILE names a notarytool keychain profile. Create one once with:
  xcrun notarytool store-credentials shawns-dotfiles \\
      --apple-id <your Apple ID> --team-id <your 10-character team ID>
(it asks for an app-specific password from https://account.apple.com).
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" "Run scripts/notarize.sh --help for the options." ;;
esac
[ $# -le 1 ] || die "notarize one file at a time"

if [ -z "${NOTARY_PROFILE:-}" ]; then
    cat >&2 <<'EOF'
Notarization is not set up: NOTARY_PROFILE is empty, so nothing was sent to Apple.

To set it up once on this Mac:
  1. Make an app-specific password at https://account.apple.com (Sign-In and Security).
  2. Store it in your keychain under a profile name:
       xcrun notarytool store-credentials shawns-dotfiles \
           --apple-id <your Apple ID> --team-id <your 10-character team ID>
  3. Run again with the profile and the disk image:
       NOTARY_PROFILE=shawns-dotfiles scripts/notarize.sh build/ShawnsDotfiles-<version>.dmg
     or, for the one 'make release' built:
       NOTARY_PROFILE=shawns-dotfiles scripts/notarize.sh build/release/<version>/ShawnsDotfiles-<version>.dmg
EOF
    exit 2
fi

if [ $# -eq 1 ]; then
    TARGET="$(absolute_path "$1")"
    [ -e "$TARGET" ] || die "nothing to notarize at $TARGET"
else
    VERSION="$(read_version)"
    TARGET="$INSTALLER_ROOT/build/ShawnsDotfiles-$VERSION.dmg"
    if [ ! -e "$TARGET" ]; then
        RELEASE_DMG="$INSTALLER_ROOT/build/release/$VERSION/ShawnsDotfiles-$VERSION.dmg"
        if [ -e "$RELEASE_DMG" ]; then
            # Named rather than picked: without FILE this script means the 'make dmg' image.
            die "nothing to notarize at $TARGET (the 'make dmg' image)" \
                "To notarize the release disk image, name it:" \
                "  NOTARY_PROFILE=$(printf '%q' "$NOTARY_PROFILE") $(printf '%q' "$INSTALLER_ROOT/scripts/notarize.sh") $(printf '%q' "$RELEASE_DMG")"
        fi
        die "nothing to notarize at $TARGET" "Make it first with: make dmg (or pass the disk image to notarize)"
    fi
fi

case "$TARGET" in
    *.dmg|*.app|*.app/) ;;
    *) die "notarize a .dmg or a .app, not $(basename "$TARGET")" ;;
esac
TARGET="${TARGET%/}"

# Apple rejects anything not signed with a Developer ID, so check before uploading. For a disk
# image the app inside matters as much as the image, but its signature is checked by the service.
AUTHORITY="$(signing_authority "$TARGET")"
case "$AUTHORITY" in
    "Developer ID Application:"*) ;;
    *)
        case "$AUTHORITY" in
            unsigned|"") how="is not signed" ;;
            "ad hoc") how="is signed ad hoc" ;;
            *) how="is signed by \"$AUTHORITY\"" ;;
        esac
        die "$(basename "$TARGET") $how; Apple only notarizes Developer ID Application signatures" \
            "Rebuild without SIGN_IDENTITY=- on a Mac that has your Developer ID certificate." ;;
esac
command -v xcrun >/dev/null 2>&1 || die "xcrun is missing" "Install Xcode or the Command Line Tools."

WORK="$(mktemp -d "${TMPDIR:-/tmp}/notarize.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

UPLOAD="$TARGET"
if [ -d "$TARGET" ]; then
    # notarytool takes zip archives, not bundles; the ticket is stapled to the app itself.
    UPLOAD="$WORK/$(basename "$TARGET" .app).zip"
    ditto -c -k --keepParent "$TARGET" "$UPLOAD"
fi

step "Submitting $(basename "$TARGET") to Apple's notary service (profile \"$NOTARY_PROFILE\")"
info "This usually takes a few minutes."
RESULT="$WORK/result.json"
if ! xcrun notarytool submit "$UPLOAD" --keychain-profile "$NOTARY_PROFILE" --wait \
        --output-format json >"$RESULT"; then
    [ ! -s "$RESULT" ] || cat "$RESULT" >&2
    die "notarytool could not submit $(basename "$TARGET")" \
        "Check the profile with: xcrun notarytool history --keychain-profile $NOTARY_PROFILE"
fi
STATUS="$(plutil -extract status raw -o - "$RESULT" 2>/dev/null || true)"
SUBMISSION="$(plutil -extract id raw -o - "$RESULT" 2>/dev/null || true)"
if [ "$STATUS" != "Accepted" ]; then
    if [ -n "$SUBMISSION" ]; then
        xcrun notarytool log "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fi
    die "Apple did not accept $(basename "$TARGET") (status: ${STATUS:-unknown}, submission ${SUBMISSION:-unknown})" \
        "The log above lists each problem. Fix them, rebuild, and run this again."
fi
info "accepted (submission $SUBMISSION)"

step "Stapling the ticket"
xcrun stapler staple "$TARGET" || die "could not staple the ticket to $(basename "$TARGET")" \
    "The submission was accepted; retry later with: xcrun stapler staple \"$TARGET\""
xcrun stapler validate "$TARGET" >/dev/null || die "the stapled ticket does not validate"

if [ -d "$TARGET" ]; then
    spctl --assess --type execute --verbose=2 "$TARGET" || die "Gatekeeper still rejects $(basename "$TARGET")"
else
    spctl --assess --type open --context context:primary-signature --verbose=2 "$TARGET" ||
        die "Gatekeeper still rejects $(basename "$TARGET")"
fi
info "notarized and stapled: $TARGET"
