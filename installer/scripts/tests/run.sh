#!/bin/bash
# Tests for the build scripts: build-app.sh, make-dmg.sh, notarize.sh, release.sh,
# check-config-gitignore.sh and make-media.sh. Usage: scripts/tests/run.sh [part of a test name]
#
# Each test runs a copy of the scripts in its own throwaway folder. Fakes from tests/fakes stand in
# for swift, codesign, hdiutil, xcrun, spctl and security where a test asks for them, so nothing is
# compiled by SwiftPM, signed with a real identity (only ad hoc), sent to Apple or read from the
# keychain. git runs without your global config, so your hooks, signing and excludes stay out.
# shellcheck source-path=SCRIPTDIR
# The globals set here are read by the *_test.sh files this sources.
# shellcheck disable=SC2034
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS_SOURCE="$(dirname "$TESTS_DIR")"
PACKAGE_SOURCE="$(dirname "$SCRIPTS_SOURCE")"
FILTER="${1:-}"

SUITE="$(mktemp -d "${TMPDIR:-/tmp}/shawn-script-tests.XXXXXX")" || exit 1
SUITE="$(cd "$SUITE" && pwd -P)"
trap 'rm -rf "$SUITE"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$SUITE"
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com
export HOME="$SUITE/home" XDG_CONFIG_HOME="$SUITE/home/.config" NO_COLOR=1
unset SIGN_IDENTITY NOTARY_PROFILE ALLOW_DIRTY ARCHS CONFIGURATION OUTPUT_DIR CONFIG_DIR APP_PATH BUILD_NUMBER RELEASE_REPO
mkdir -p "$HOME"
BASE_PATH="$PATH"

# Tiny real executables, one per architecture, that the fake swift hands out as build products.
export FAKE_BINARIES="$SUITE/binaries"
mkdir -p "$FAKE_BINARIES"
for arch in arm64 x86_64; do
    if ! printf 'int main(void) { return 0; }\n' | cc -arch "$arch" -x c -o "$FAKE_BINARIES/$arch" - 2>"$SUITE/cc.log"; then
        cat "$SUITE/cc.log" >&2
        echo "error: cannot compile a test executable for $arch with cc; install the Command Line Tools" >&2
        exit 1
    fi
done

# The identity the fake codesign pretends is in the keychain twice.
export FAKE_IDENTITY_NAME="Developer ID Application: Test Person (TEAM123456)"
FAKE_SHA1="0123456789ABCDEF0123456789ABCDEF01234567"

# MARK: Helpers for tests (each test runs in a subshell with set -e, inside its folder $T)

fail() {
    printf 'assertion failed: %s\n' "$*" >&2
    exit 1
}

# Runs a command, keeping its stdout in $OUT, its stderr in $ERR and its exit status in $STATUS.
run() {
    STATUS=0
    "$@" >"$T/stdout" 2>"$T/stderr" || STATUS=$?
    OUT="$(cat "$T/stdout")"
    ERR="$(cat "$T/stderr")"
}

assert_status() {
    [ "$STATUS" = "$1" ] || fail "expected exit status $1, got $STATUS"$'\n'"--- stdout:"$'\n'"$OUT"$'\n'"--- stderr:"$'\n'"$ERR"
}

assert_eq() { # <expected> <actual> [what]
    [ "$1" = "$2" ] || fail "${3:-value}: expected [$1], got [$2]"
}

assert_contains() { # <text> <part> [what]
    case "$1" in *"$2"*) ;; *) fail "${3:-output} does not contain [$2]:"$'\n'"$1" ;; esac
}

assert_not_contains() { # <text> <part> [what]
    case "$1" in *"$2"*) fail "${3:-output} contains [$2]:"$'\n'"$1" ;; *) ;; esac
}

# Puts these fakes first on PATH for the rest of the test.
use_fakes() {
    local name
    for name in "$@"; do
        cp "$TESTS_DIR/fakes/$name" "$T/bin/$name"
        chmod +x "$T/bin/$name"
    done
}

# A minimal copy of the installer package at <dir> that the build scripts accept: the real scripts
# and Resources, a one-line ShawnCore.swift with version 9.8.7, Package.swift, Package.resolved and
# a config folder.
make_package() {
    local dir="$1"
    mkdir -p "$dir/scripts" "$dir/Resources" "$dir/Sources/ShawnCore" "$dir/Sources/App" "$dir/config/steps"
    cp -p "$SCRIPTS_SOURCE"/*.sh "$SCRIPTS_SOURCE/make-icon.swift" "$dir/scripts/"
    cp -p "$PACKAGE_SOURCE/Resources/Info.plist" "$PACKAGE_SOURCE/Resources/AppIcon.icns" "$dir/Resources/"
    # Newer than make-icon.swift, so build-app.sh does not redraw it.
    touch "$dir/Resources/AppIcon.icns"
    cp "$PACKAGE_SOURCE/.gitignore" "$dir/.gitignore"
    printf 'public enum ShawnCore {\n    public static let version = "9.8.7"\n}\n' >"$dir/Sources/ShawnCore/ShawnCore.swift"
    printf 'print("hello")\n' >"$dir/Sources/App/main.swift"
    printf '// swift-tools-version: 6.0\n' >"$dir/Package.swift"
    printf '{ "pins": [], "version": 3 }\n' >"$dir/Package.resolved"
    printf 'schema: 1\nname: Test\n' >"$dir/config/installer.yaml"
}

# A git repository at $T/<name> holding the package at <path in repo> ("installer", as in the real
# repository, or "." for the repository root), everything committed. Sets REPO and PKG.
new_checkout() {
    REPO="$T/$1"
    if [ "${2:-installer}" = . ]; then PKG="$REPO"; else PKG="$REPO/${2:-installer}"; fi
    make_package "$PKG"
    git init -q "$REPO"
    git -C "$REPO" add -A
    git -C "$REPO" commit -q -m "fixture"
}

# Sets INFO_VERSION, INFO_COMMIT and INFO_TREE from a build-info.json, failing the test when the
# file or one of the keys is missing (so a missing file never passes for an empty value).
read_info_file() { # <build-info.json>
    [ -f "$1" ] || fail "there is no $1"
    INFO_VERSION="$(plutil -extract version raw -o - "$1")" || fail "$1 has no version"
    INFO_COMMIT="$(plutil -extract commit raw -o - "$1")" || fail "$1 has no commit"
    INFO_TREE="$(plutil -extract sourceTree raw -o - "$1")" || fail "$1 has no sourceTree"
}

# The content id the shawn CLI computes for the package at <path in repo with trailing slash>.
expected_content_id() {
    local prefix="$1" path id ids=""
    for path in Sources Package.swift Package.resolved; do
        id="$(git -C "$REPO" rev-parse -q --verify "HEAD:$prefix$path")" || id="-"
        ids="${ids:+$ids,}$id"
    done
    printf '%s\n' "$ids"
}

# MARK: Runner

for file in "$TESTS_DIR"/*_test.sh; do
    # shellcheck source=/dev/null
    . "$file"
done

passed=0 failed=0
for name in $(declare -F | awk '$3 ~ /^test_/ { print $3 }'); do
    case "$name" in *"$FILTER"*) ;; *) continue ;; esac
    T="$SUITE/$name"
    mkdir -p "$T/bin"
    (
        set -e
        export PATH="$T/bin:$BASE_PATH" FAKE_LOG="$T/fake.log" FAKE_BUILD_DIR="$T/swift-build"
        : >"$FAKE_LOG"
        cd "$T"
        "$name"
    ) >"$T.log" 2>&1
    # Not `if ( … )`: a subshell tested by `if` or `||` runs with set -e switched off.
    # shellcheck disable=SC2181
    if [ $? -eq 0 ]; then
        passed=$((passed + 1))
        printf 'ok    %s\n' "$name"
    else
        failed=$((failed + 1))
        printf 'FAIL  %s\n' "$name"
        sed 's/^/      /' "$T.log"
    fi
done

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ $((passed + failed)) -gt 0 ] || { echo "no test matches \"$FILTER\"" >&2; exit 1; }
[ "$failed" = 0 ]
