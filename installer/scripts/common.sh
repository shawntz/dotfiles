# shellcheck shell=bash
# The globals set here are read by the scripts that source this file.
# shellcheck disable=SC2034
#
# Shared helpers for the build scripts. Sourced, never run.
#
# Everything here must work with macOS's /bin/bash 3.2: no associative arrays,
# no mapfile, and empty arrays expanded as ${a[@]+"${a[@]}"} under `set -u`.

# The installer package root (the directory holding Package.swift), whatever the caller's cwd.
INSTALLER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# The app is Dotfiles.app. The project it belongs to keeps its own name, which titles the releases.
APP_NAME="Dotfiles"
PROJECT_NAME="Shawn's Dotfiles"
APP_BUNDLE_NAME="$APP_NAME.app"
APP_BUNDLE_ID="com.shawnschwartz.dotfiles"
APP_EXECUTABLE="ShawnsDotfiles"
# What gives the disk image's Finder window its look, drawn by make-dmg-art.sh and packed by
# make-dmg.sh: the picture behind the icons and Finder's layout file. The picture's name in the
# image starts with a period, so Finder hides it.
DMG_ART_DIR="$INSTALLER_ROOT/Resources/dmg"
DMG_PICTURE_NAME=".background.tiff"
RELEASE_REPO="${RELEASE_REPO:-shawntz/dotfiles}"

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    _bold=$'\033[1m' _dim=$'\033[2m' _red=$'\033[31m' _yellow=$'\033[33m' _reset=$'\033[0m'
else
    _bold='' _dim='' _red='' _yellow='' _reset=''
fi

step() { printf '%s==>%s %s%s%s\n' "$_bold" "$_reset" "$_bold" "$*" "$_reset" >&2; }
info() { printf '    %s\n' "$*" >&2; }
note() { printf '%s    %s%s\n' "$_dim" "$*" "$_reset" >&2; }
warn() { printf '%swarning:%s %s\n' "$_yellow" "$_reset" "$*" >&2; }
die() {
    printf '%serror:%s %s\n' "$_red" "$_reset" "$1" >&2
    shift
    local line
    for line in "$@"; do printf '       %s\n' "$line" >&2; done
    exit 1
}

# Resolves a path given on the command line against the caller's cwd; prints an absolute path.
absolute_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$(pwd -P)" "$1" ;;
    esac
}

# Prints ShawnCore.version, the single source of truth for the app and CLI version.
read_version() {
    local source="$INSTALLER_ROOT/Sources/ShawnCore/ShawnCore.swift" version
    [ -f "$source" ] || die "cannot find $source" "Run this from a checkout of the installer package."
    version="$(sed -n 's/^[[:space:]]*public static let version = "\([^"]*\)".*/\1/p' "$source" | head -n 1)"
    [ -n "$version" ] || die "no 'public static let version = \"…\"' line in $source"
    # CFBundleShortVersionString only accepts up to three dot-separated integers.
    if ! printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
        die "version \"$version\" in $source is not of the form 1.2.3" \
            "macOS bundle versions must be plain numbers; drop any suffix such as -beta."
    fi
    printf '%s\n' "$version"
}

# Prints "<sha1>\t<name>" for the first valid "Developer ID Application" identity in the
# keychain search list, or nothing. Reads the keychain only.
find_developer_id() {
    command -v security >/dev/null 2>&1 || return 0
    security find-identity -v -p codesigning 2>/dev/null |
        awk -F'"' '/"Developer ID Application:/ { split($1, a, " "); printf "%s\t%s\n", a[2], $2; exit }'
}

# Decides the signing identity from SIGN_IDENTITY and sets SIGN_ID (what codesign gets) and
# SIGN_LABEL (what people read). Unset or empty = auto-detect, "-" = ad hoc.
resolve_identity() {
    local requested="${SIGN_IDENTITY:-}" found
    if [ -z "$requested" ]; then
        found="$(find_developer_id)"
        if [ -n "$found" ]; then
            SIGN_ID="${found%%$'\t'*}"
            SIGN_LABEL="${found#*$'\t'}"
            SIGN_SOURCE="found in your keychain"
        else
            SIGN_ID="-"
            SIGN_LABEL="ad hoc"
            SIGN_SOURCE="no Developer ID Application identity in your keychain"
        fi
    elif [ "$requested" = "-" ]; then
        SIGN_ID="-"
        SIGN_LABEL="ad hoc"
        SIGN_SOURCE="SIGN_IDENTITY=-"
    else
        SIGN_ID="$requested"
        SIGN_LABEL="$requested"
        SIGN_SOURCE="SIGN_IDENTITY"
    fi
}

is_ad_hoc() { [ "${SIGN_ID:-}" = "-" ]; }

# Sets CODESIGN_FLAGS: hardened runtime always; a secure timestamp only for a real identity
# (ad hoc signatures cannot carry one, and asking Apple's timestamp server needs the network).
set_codesign_flags() {
    if is_ad_hoc; then
        CODESIGN_FLAGS=(--force --options runtime --timestamp=none --sign -)
    else
        CODESIGN_FLAGS=(--force --options runtime --timestamp --sign "$SIGN_ID")
    fi
}

# Prints the signing authority of a signed file ("ad hoc" when it has none).
signing_authority() {
    local details
    details="$(codesign -dvv "$1" 2>&1)" || { printf 'unsigned\n'; return 0; }
    if printf '%s\n' "$details" | grep -q '^Signature=adhoc'; then
        printf 'ad hoc\n'
    else
        printf '%s\n' "$details" | sed -n 's/^Authority=//p' | head -n 1
    fi
}

# Prints the SHA-1 of the certificate that signed a file, the form `security find-identity` lists
# and `codesign --sign` accepts. Unlike the certificate's name, it is never ambiguous: after a
# Developer ID renewal the old and the new certificate have the same name. Fails when the file has
# no certificate. <scratch dir> receives the extracted certificates.
signing_certificate_sha1() { # <signed file> <scratch dir>
    local prefix="$2/signing-certificate" sha
    rm -f "$prefix"[0-9]*
    codesign -d --extract-certificates="$prefix" "$1" >/dev/null 2>&1 || return 1
    # Certificate 0 is the leaf, the one that holds the signing key.
    [ -s "${prefix}0" ] || return 1
    sha="$(shasum -a 1 "${prefix}0" | awk '{ print toupper($1) }')"
    printf '%s' "$sha" | grep -Eq '^[0-9A-F]{40}$' || return 1
    printf '%s\n' "$sha"
}

# The paths, relative to the package, whose content decides what the binaries are. The shawn CLI
# uses the same list (SelfUpdater.sourcePaths) to decide whether it must rebuild itself.
SOURCE_PATHS=(Sources Package.swift Package.resolved)

# Works out which committed sources a build comes from, read-only. Sets:
#   SOURCE_GIT      1 inside a git work tree, else 0
#   SOURCE_PREFIX   the package's path inside the repo with a trailing slash ("installer/"; "" at the root)
#   SOURCE_COMMIT   the sha of HEAD, or empty
#   SOURCE_CHANGES  `git status --porcelain` for SOURCE_PATHS: uncommitted changes and untracked files
#   SOURCE_TREE     the content id the shawn CLI computes (GitRepo.contentID): the git object ids of
#                   <prefix>Sources, <prefix>Package.swift and <prefix>Package.resolved at HEAD, joined
#                   by commas, "-" for one that is not committed. Empty (unknown) outside git, without
#                   a commit, or when SOURCE_CHANGES is not empty, because then the build is not what
#                   HEAD holds.
source_provenance() {
    SOURCE_GIT=0 SOURCE_PREFIX="" SOURCE_COMMIT="" SOURCE_CHANGES="" SOURCE_TREE=""
    command -v git >/dev/null 2>&1 || return 0
    [ "$(git -C "$INSTALLER_ROOT" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || return 0
    SOURCE_GIT=1
    SOURCE_PREFIX="$(git -C "$INSTALLER_ROOT" rev-parse --show-prefix)" || return 0
    SOURCE_COMMIT="$(git -C "$INSTALLER_ROOT" rev-parse -q --verify HEAD)" || { SOURCE_COMMIT=""; return 0; }
    # Untracked files are listed whatever status.showUntrackedFiles says: SwiftPM compiles them too.
    # --no-optional-locks: only looking, so never take the index lock from a git command running alongside.
    if ! SOURCE_CHANGES="$(git -C "$INSTALLER_ROOT" --no-optional-locks status --porcelain --untracked-files=all \
            -- "${SOURCE_PATHS[@]}")"; then
        SOURCE_CHANGES="(git status failed)"
        return 0
    fi
    [ -z "$SOURCE_CHANGES" ] || return 0
    local path id ids="" committed=0
    for path in "${SOURCE_PATHS[@]}"; do
        id="$(git -C "$INSTALLER_ROOT" rev-parse -q --verify "HEAD:$SOURCE_PREFIX$path")" || id="-"
        [ "$id" = "-" ] || committed=1
        ids="${ids:+$ids,}$id"
    done
    # GitRepo.contentID has no id when none of the paths is committed; neither does this.
    [ "$committed" = 0 ] || SOURCE_TREE="$ids"
}

# Writes the build-info.json the shawn-cli installer kind reads from the app's Resources folder:
# {"version", "commit", "sourceTree"} (see source_provenance).
write_build_info() { # <destination file> <version>
    cat >"$1" <<EOF
{
  "version": "$2",
  "commit": "$SOURCE_COMMIT",
  "sourceTree": "$SOURCE_TREE"
}
EOF
    plutil -convert xml1 -o /dev/null "$1" 2>/dev/null || die "wrote an invalid $1"
}

# Succeeds when Finder's layout file places an icon for <file name>. The file stores each name as
# UTF-16 with the code "Iloc" right behind it.
layout_places() { # <layout file> <file name>
    local name
    name="$(printf '%s' "$2" | iconv -f UTF-8 -t UTF-16BE | xxd -p | tr -d '\n')" || return 1
    [ -n "$name" ] || return 1
    xxd -p "$1" | tr -d '\n' | grep -q "${name}496c6f63"
}

# Reads a key from an Info.plist (or a JSON file).
plist_value() { plutil -extract "$2" raw -o - "$1" 2>/dev/null; }

# Prints a file's size for people: 812 B, 14.2 KB, 3.8 MB.
file_size() {
    stat -f %z "$1" | awk '{
        if ($1 < 1024) printf "%d B\n", $1
        else if ($1 < 1048576) printf "%.1f KB\n", $1 / 1024
        else printf "%.1f MB\n", $1 / 1048576 }'
}
