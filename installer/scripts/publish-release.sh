#!/bin/bash
# Publishes what release.sh built as the GitHub release shawn-v<version>. The release workflow runs
# this on master, and a person can run it too. Run with --help for the options.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
    cat <<EOF
Usage: scripts/publish-release.sh [options] [DIR]

Publishes the files scripts/release.sh made in DIR as the release shawn-v<version> on GitHub:
the disk image, the CLI tarball, its checksum and shawn-cli.json. DIR defaults to
build/release/<version>.

It uploads everything to a draft and publishes the draft last. The tag appears only then, with
every file in place, because shawn on other Macs looks for the tag first and then for the files.

  --allow-unnotarized   publish a disk image that Apple has not notarized. Gatekeeper blocks the
                        app on other Macs until the person allows it, and the release notes say so.
  -n, --dry-run         check the files and print the gh commands. It asks GitHub nothing and
                        publishes nothing.
  -h, --help            show this help

Environment:
  RELEASE_REPO   GitHub repo the release goes to [default $RELEASE_REPO]
  GH_TOKEN       as for gh. It needs write access to the repo's contents.

It leaves a published release alone (exit status 0). It deletes a draft of the same tag and makes
it again, so do not run it while someone else is still uploading to that draft. It stops when the
tag already exists on GitHub and points at another commit than the one the files were built from.
EOF
}

ALLOW_UNNOTARIZED=0
DRY_RUN=0
RELEASE_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --allow-unnotarized) ALLOW_UNNOTARIZED=1; shift ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $1" "Run scripts/publish-release.sh --help for the options." ;;
        *) [ -z "$RELEASE_DIR" ] || die "publish one folder at a time"; RELEASE_DIR="$1"; shift ;;
    esac
done

VERSION="$(read_version)"
TAG="shawn-v$VERSION"
RELEASE_DIR="$(absolute_path "${RELEASE_DIR:-$INSTALLER_ROOT/build/release/$VERSION}")"
RELEASE_DIR="${RELEASE_DIR%/}"
TARBALL_NAME="shawn-$VERSION-macos-arm64.tar.gz"
DMG="$RELEASE_DIR/ShawnsDotfiles-$VERSION.dmg"
TARBALL="$RELEASE_DIR/$TARBALL_NAME"
MANIFEST="$RELEASE_DIR/shawn-cli.json"
URL="https://github.com/$RELEASE_REPO/releases/download/$TAG/$TARBALL_NAME"
ASSETS=("$DMG" "$TARBALL" "$TARBALL.sha256" "$MANIFEST")

# MARK: The files are the release of this version, for this repo, from these sources

[ -d "$RELEASE_DIR" ] || die "there is no $RELEASE_DIR" "Build the release first: scripts/release.sh"
for asset in "${ASSETS[@]}"; do
    [ -s "$asset" ] || die "$(basename "$asset") is missing from $RELEASE_DIR" \
        "Build the release for version $VERSION first: scripts/release.sh"
done

manifest_value() { plutil -extract "$1" raw -o - "$MANIFEST" 2>/dev/null; }
for pair in "version=$VERSION" "tag=$TAG" "url=$URL"; do
    key="${pair%%=*}"
    found="$(manifest_value "$key")" || die "shawn-cli.json has no $key"
    [ "$found" = "${pair#*=}" ] || die "shawn-cli.json has $key \"$found\", and this release needs \"${pair#*=}\"" \
        "Build the release again for $RELEASE_REPO at version $VERSION: scripts/release.sh"
done

SHA256="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
[ "$(manifest_value sha256)" = "$SHA256" ] || die "shawn-cli.json does not hold the checksum of $TARBALL_NAME" \
    "Build the release again: scripts/release.sh"
[ "$(awk '{print $1; exit}' "$TARBALL.sha256")" = "$SHA256" ] || die "$TARBALL_NAME.sha256 does not hold the checksum of $TARBALL_NAME" \
    "Build the release again: scripts/release.sh"

# The tag goes on the commit this checkout is at, so that commit must hold the sources of the build.
source_provenance
if [ "$SOURCE_GIT" != 1 ] || [ -z "$SOURCE_COMMIT" ]; then
    die "this is not a git checkout with a commit" "Publish from the checkout the release was built in."
fi
if [ -n "$SOURCE_CHANGES" ]; then
    printf '%s\n' "$SOURCE_CHANGES" >&2
    die "Sources/ or Package.* have uncommitted changes (listed above), so HEAD does not say what this checkout holds" \
        "Commit or stash them, then run this again."
fi
BUILT_TREE="$(manifest_value sourceTree)" || BUILT_TREE=""
[ -n "$BUILT_TREE" ] || die "shawn-cli.json has no sourceTree, so nobody knows which sources the build holds" \
    "Build the release again from committed sources, without ALLOW_DIRTY: scripts/release.sh"
[ "$BUILT_TREE" = "$SOURCE_TREE" ] || die "the release was built from other sources than this checkout holds at HEAD" \
    "Check out the commit it was built from, or build it again: scripts/release.sh"

# MARK: Notarized or not

AUTHORITY="$(signing_authority "$DMG")"
NOTARIZED=0
case "$AUTHORITY" in
    "Developer ID Application:"*)
        # A stapled ticket is how the image proves it offline.
        if xcrun stapler validate "$DMG" >/dev/null 2>&1; then NOTARIZED=1; fi ;;
esac

step "Release $TAG for $RELEASE_REPO, from ${SOURCE_COMMIT:0:12}"
for asset in "${ASSETS[@]}"; do info "$(basename "$asset")  ($(file_size "$asset"))"; done
info "disk image signature: $AUTHORITY"
info "notarized:            $([ "$NOTARIZED" = 1 ] && echo yes || echo no)"

SCRATCH="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${SCRATCH%/}/publish-release.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

NOTES=""
if [ "$NOTARIZED" = 0 ]; then
    [ "$ALLOW_UNNOTARIZED" = 1 ] || die "Apple has not notarized $(basename "$DMG"), so Gatekeeper blocks the app on other Macs" \
        "Sign with a Developer ID and notarize it (see scripts/release.sh --help), then run this again." \
        "To publish it as it is, run scripts/publish-release.sh --allow-unnotarized. The release notes then say how to open it."
    warn "publishing a disk image that Apple has not notarized (--allow-unnotarized)"
    NOTES="$WORK/release-notes.md"
    cat >"$NOTES" <<EOF
Apple has not notarized this build, so macOS blocks the app the first time you open it. [If macOS won't open it](https://github.com/$RELEASE_REPO/blob/HEAD/installer/README.md#if-macos-wont-open-it) says how to open it anyway.

EOF
fi

# MARK: Publish

CREATE=(gh release create "$TAG" --repo "$RELEASE_REPO" --target "$SOURCE_COMMIT" --title "$PROJECT_NAME $VERSION" --draft --generate-notes)
[ -z "$NOTES" ] || CREATE+=(--notes-file "$NOTES")
CREATE+=("${ASSETS[@]}")
PUBLISH=(gh release edit "$TAG" --repo "$RELEASE_REPO" --draft=false)

print_command() {
    local word line=""
    for word in "$@"; do line="$line$(printf '%q' "$word") "; done
    printf '%s\n' "${line% }"
}

if [ "$DRY_RUN" = 1 ]; then
    note "Dry run: nothing is published, and GitHub is not asked what it already holds. The commands would be:"
    print_command "${CREATE[@]}"
    print_command "${PUBLISH[@]}"
    if [ -n "$NOTES" ]; then
        note "The notes file lasts only while this script runs. It would hold:"
        sed 's/^/    /' "$NOTES" >&2
    fi
    exit 0
fi

command -v gh >/dev/null 2>&1 || die "gh (the GitHub CLI) is not installed" "Install it with: brew install gh"

# isDraft is "true" for a draft and "false" for a published release. With neither, gh says "release not found".
if EXISTING="$(gh release view "$TAG" --repo "$RELEASE_REPO" --json isDraft --jq .isDraft 2>"$WORK/view.err")"; then
    :
elif grep -qi 'release not found' "$WORK/view.err"; then
    EXISTING=none
else
    cat "$WORK/view.err" >&2
    die "could not ask GitHub whether $TAG is released" "Check the network and GH_TOKEN, then run this again."
fi
case "$EXISTING" in
    false)
        note "$TAG is already published on $RELEASE_REPO. Nothing to do."
        exit 0 ;;
    true)
        step "Deleting the draft of $TAG that an earlier run left"
        gh release delete "$TAG" --repo "$RELEASE_REPO" --yes >&2 || die "could not delete the draft of $TAG" ;;
esac

# gh leaves a tag that already exists where it is and ignores --target. Deleting a release keeps its tag, so a
# release made again could put files from this commit under a tag that points at another one.
if TAGGED="$(gh api "repos/$RELEASE_REPO/commits/tags/$TAG" --jq .sha 2>/dev/null)" && [ -n "$TAGGED" ] && [ "$TAGGED" != "$SOURCE_COMMIT" ]; then
    die "the tag $TAG is already on $RELEASE_REPO and points at ${TAGGED:0:12}, not at ${SOURCE_COMMIT:0:12}" \
        "The release would carry files from one commit under a tag for another." \
        "Delete the tag (git push --delete origin $TAG), or bump the version, then run this again."
fi

step "Uploading to a draft of $TAG"
"${CREATE[@]}" >&2 || die "gh could not create the draft of $TAG" \
    "Nothing is published. Fix the problem above and run this again."

step "Publishing $TAG"
"${PUBLISH[@]}" >&2 || die "the draft of $TAG is uploaded but gh could not publish it" \
    "Publish it by hand: $(print_command "${PUBLISH[@]}")"

info "published: https://github.com/$RELEASE_REPO/releases/tag/$TAG"
printf 'https://github.com/%s/releases/tag/%s\n' "$RELEASE_REPO" "$TAG"
