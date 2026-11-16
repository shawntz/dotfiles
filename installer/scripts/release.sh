#!/bin/bash
# Builds everything a release needs (the app, disk image, CLI tarball and its manifest)
# and prints the `gh release create` command to publish it. It never publishes, tags or pushes:
# publish-release.sh does that.
# Run with --help for the options.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
    cat <<EOF
Usage: scripts/release.sh [options]

Builds release artifacts for ShawnCore.version into build/release/<version>/:
  $APP_BUNDLE_NAME                      for Apple silicon (arm64), signed
  ShawnsDotfiles-<version>.dmg              notarized when NOTARY_PROFILE is set
  shawn-<version>-macos-arm64.tar.gz        the shawn CLI, for self-update on other Macs
  shawn-<version>-macos-arm64.tar.gz.sha256
  shawn-cli.json                            {version, tag, url, sha256, sourceTree, minimumMacOS}
then prints the 'gh release create shawn-v<version> ...' command for you to run. It goes to
stdout only when the release is ready to publish (Developer ID signed and notarized); otherwise
the summary says what to do first. Nothing is uploaded, tagged or pushed.

sourceTree is the same source content id the app's build-info.json holds (see build-app.sh).

  -o, --output DIR   where the artifacts go      [default build/release/<version>]
  -h, --help         show this help

Environment:
  SIGN_IDENTITY   as for build-app.sh (unset = your Developer ID, "-" = ad hoc for a dry run)
  NOTARY_PROFILE  notarytool keychain profile; unset = skip notarization (see notarize.sh)
  ALLOW_DIRTY=1   release even though Sources/ or Package.* have uncommitted changes
                  (sourceTree is then empty: the sources are unknown)
  RELEASE_REPO    GitHub repo the release lives in [default $RELEASE_REPO]
  CONFIG_DIR      config directory to bundle       [default config/]

To cut a release by hand: bump 'version' in Sources/ShawnCore/ShawnCore.swift, commit, push, then
run this and scripts/publish-release.sh, or the command this prints. On GitHub, the release
workflow does the same for each new version on master.
EOF
}

OUTPUT_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output) [ $# -ge 2 ] || die "$1 needs a value"; OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" "Run scripts/release.sh --help for the options." ;;
    esac
done

VERSION="$(read_version)"
TAG="shawn-v$VERSION"
OUTPUT_DIR="$(absolute_path "${OUTPUT_DIR:-$INSTALLER_ROOT/build/release/$VERSION}")"
SCRIPTS="$INSTALLER_ROOT/scripts"
APP="$OUTPUT_DIR/$APP_BUNDLE_NAME"
TARBALL_NAME="shawn-$VERSION-macos-arm64.tar.gz"
TARBALL="$OUTPUT_DIR/$TARBALL_NAME"
MANIFEST="$OUTPUT_DIR/shawn-cli.json"
DMG="$OUTPUT_DIR/ShawnsDotfiles-$VERSION.dmg"
URL="https://github.com/$RELEASE_REPO/releases/download/$TAG/$TARBALL_NAME"

# MARK: Source state (read-only git)

PUSHED=1
# SOURCE_TREE is the content id the shawn CLI compares with its checkout; build-app.sh records the
# same value in the app's build-info.json.
source_provenance
COMMIT="$SOURCE_COMMIT"
if [ "$SOURCE_GIT" = 1 ]; then
    PREFIX="$SOURCE_PREFIX"
    [ -n "$COMMIT" ] || die "this checkout has no commits yet" "Commit the installer before releasing it."
    if [ -n "$SOURCE_CHANGES" ]; then
        if [ "${ALLOW_DIRTY:-}" = 1 ]; then
            warn "Sources/ or Package.* have uncommitted changes, so shawn-cli.json gets an empty sourceTree (unknown sources)."
        else
            printf '%s\n' "$SOURCE_CHANGES" >&2
            die "Sources/ or Package.* have uncommitted changes (listed above)" \
                "Commit them first so the release matches ${PREFIX}Sources at HEAD, or set ALLOW_DIRTY=1."
        fi
    elif [ -z "$SOURCE_TREE" ]; then
        die "${PREFIX}Sources is not committed at HEAD" "Commit the installer before releasing it."
    fi
    if [ -n "$(git -C "$INSTALLER_ROOT" status --porcelain -- config)" ]; then
        warn "config/ has uncommitted changes; they will be bundled into the app."
    fi
    if git -C "$INSTALLER_ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
        warn "the tag $TAG already exists here; bump the version in Sources/ShawnCore/ShawnCore.swift for a new release."
    fi
    if [ -z "$(git -C "$INSTALLER_ROOT" branch -r --contains "$COMMIT" 2>/dev/null)" ]; then
        PUSHED=0
    fi
else
    warn "not in a git checkout, so shawn-cli.json gets an empty sourceTree and the release no --target."
fi

# MARK: Build, sign, pack, notarize

# One identity for every step, decided once.
resolve_identity
export SIGN_IDENTITY="$SIGN_ID"
step "Release $TAG, signed with $SIGN_LABEL ($SIGN_SOURCE)"
mkdir -p "$OUTPUT_DIR"

CONFIGURATION=release OUTPUT_DIR="$OUTPUT_DIR" "$SCRIPTS/build-app.sh" >/dev/null

# The tarball ships the app's own shawn, so the manifest must describe what the app says it was built from.
BUILD_INFO="$APP/Contents/Resources/build-info.json"
BUILT_TREE="$(plist_value "$BUILD_INFO" sourceTree)" || die "the app has no readable $BUILD_INFO" "Rebuild with scripts/build-app.sh."
[ "$BUILT_TREE" = "$SOURCE_TREE" ] ||
    die "Sources/ or Package.* changed while the release was building" "Run scripts/release.sh again."

step "Validating the bundled config with the built CLI"
# The release binary must not try to update itself while it is being checked.
SHAWN_NO_SELF_UPDATE=1 SHAWN_NO_UPDATE=1 NO_COLOR=1 \
    "$APP/Contents/Helpers/shawn" config validate "$APP/Contents/Resources/config" >&2 ||
    die "the bundled config does not validate" "Fix the problems listed above, then run this again."

OUTPUT_DIR="$OUTPUT_DIR" APP_PATH="$APP" "$SCRIPTS/make-dmg.sh" >/dev/null

NOTARIZED=0
if [ -z "${NOTARY_PROFILE:-}" ]; then
    note "NOTARY_PROFILE is not set, so the disk image is not notarized (see scripts/notarize.sh --help)."
elif is_ad_hoc; then
    warn "NOTARY_PROFILE is set, but an ad hoc build cannot be notarized; skipping."
else
    "$SCRIPTS/notarize.sh" "$DMG"
    NOTARIZED=1
fi

# MARK: CLI tarball and manifest

step "Packing the shawn CLI"
# The binary inside the app is the one the disk image's notarization covers.
COPYFILE_DISABLE=1 tar -czf "$TARBALL" --uid 0 --gid 0 --uname root --gname wheel \
    --no-mac-metadata --no-xattrs --no-acls --no-fflags -C "$APP/Contents/Helpers" shawn
SHA256="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
printf '%s  %s\n' "$SHA256" "$TARBALL_NAME" >"$TARBALL.sha256"

# The macOS the binaries need, as the app's Info.plist declares it. shawn compares it with the Mac it runs on
# before it replaces itself with this release.
MINIMUM_MACOS="$(plist_value "$APP/Contents/Info.plist" LSMinimumSystemVersion)" || die "the app's Info.plist has no LSMinimumSystemVersion"
MINIMUM_MACOS="${MINIMUM_MACOS%%.*}"
printf '%s' "$MINIMUM_MACOS" | grep -Eq '^[0-9]+$' || die "the app's LSMinimumSystemVersion does not start with a number"

cat >"$MANIFEST" <<EOF
{
  "version": "$VERSION",
  "tag": "$TAG",
  "url": "$URL",
  "sha256": "$SHA256",
  "sourceTree": "$SOURCE_TREE",
  "minimumMacOS": $MINIMUM_MACOS
}
EOF
# Read the manifest back the way a JSON parser sees it.
plutil -convert xml1 -o /dev/null "$MANIFEST" || die "wrote an invalid $MANIFEST"
for pair in "version=$VERSION" "tag=$TAG" "url=$URL" "sha256=$SHA256" "sourceTree=$SOURCE_TREE" "minimumMacOS=$MINIMUM_MACOS"; do
    key="${pair%%=*}"
    [ "$(plutil -extract "$key" raw -o - "$MANIFEST")" = "${pair#*=}" ] || die "shawn-cli.json has the wrong $key"
done

# MARK: Summary

ASSETS=("$DMG" "$TARBALL" "$TARBALL.sha256" "$MANIFEST")
step "Artifacts in $OUTPUT_DIR"
for asset in "${ASSETS[@]}"; do info "$(basename "$asset")  ($(file_size "$asset"))"; done
info "app signature: $(signing_authority "$APP")"
info "notarized:     $([ "$NOTARIZED" = 1 ] && echo yes || echo no)"
info "sourceTree:    ${SOURCE_TREE:-(none)}"

READY=1
if is_ad_hoc; then
    READY=0
    warn "this build is signed ad hoc. Do not publish it: Gatekeeper blocks the app on other Macs."
elif [ "$NOTARIZED" = 0 ]; then
    READY=0
    # notarize.sh without a file means the 'make dmg' image, not this one, so name this one.
    warn "the disk image is not notarized, so Gatekeeper blocks the app on other Macs. Notarize it before publishing:"
    info "NOTARY_PROFILE=<your profile> $(printf '%q' "$SCRIPTS/notarize.sh") $(printf '%q' "$DMG")"
    note "(make a profile once: see scripts/notarize.sh --help)"
fi
if [ "$PUSHED" = 0 ]; then
    warn "HEAD ($COMMIT) is not on any remote branch yet; push it before creating the release."
fi

publish_command() {
    printf 'gh release create %s \\\n' "$TAG"
    printf '  --repo %s \\\n' "$RELEASE_REPO"
    [ -z "$COMMIT" ] || printf '  --target %s \\\n' "$COMMIT"
    printf '  --title "%s %s" \\\n' "$APP_NAME" "$VERSION"
    printf '  --generate-notes \\\n'
    local last=$((${#ASSETS[@]} - 1)) index
    for index in "${!ASSETS[@]}"; do
        if [ "$index" -eq "$last" ]; then printf '  %q\n' "${ASSETS[$index]}"; else printf '  %q \\\n' "${ASSETS[$index]}"; fi
    done
}

# When the release is ready, the command is the only thing on stdout, so `scripts/release.sh >
# publish.sh` captures it. When it is not, stdout stays empty and the command goes to the screen
# only, after what has to happen first.
if [ "$READY" = 1 ]; then
    printf '\nTo publish, run:\n\n' >&2
    publish_command
elif is_ad_hoc; then
    printf '\nA release signed with your Developer ID would be published with:\n\n' >&2
    publish_command >&2
else
    printf '\nOnce the disk image is notarized, publish with:\n\n' >&2
    publish_command >&2
fi
