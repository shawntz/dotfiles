#!/bin/bash
# Puts a signing certificate into a temporary keychain on a CI runner, and takes it out again.
# The release workflow runs this. Run with --help for the options.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
    cat <<EOF
Usage: scripts/ci-keychain.sh create
       scripts/ci-keychain.sh delete

create  makes a new keychain and imports the certificate and its private key from SIGNING_P12.
        The key cannot be exported again, and only codesign may use it, without a prompt. The
        keychain goes first in the search list and becomes the default keychain, so notarytool
        stores its profile there too.
delete  removes that keychain. Run it at the end of the job, whatever happened before.

Environment:
  SIGNING_P12            the .p12 file, base64-encoded (create)
  SIGNING_P12_PASSWORD   its password (create)
  KEYCHAIN_PATH          where the keychain goes [default \$RUNNER_TEMP/release-signing.keychain-db]

This is for a CI runner that is thrown away after the job. On your own Mac it would change your
default keychain, so it refuses to run unless CI is "true".
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    create|delete) ACTION="$1" ;;
    "") die "say create or delete" "Run scripts/ci-keychain.sh --help for the options." ;;
    *) die "unknown argument: $1" "Run scripts/ci-keychain.sh --help for the options." ;;
esac
[ $# -eq 1 ] || die "one argument: create or delete"

[ "${CI:-}" = true ] || die "this changes the default keychain, so it only runs on a CI runner (CI=true)" \
    "On your own Mac, sign with the identity in your keychain: scripts/release.sh"

SCRATCH="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
SCRATCH="${SCRATCH%/}"
KEYCHAIN_PATH="${KEYCHAIN_PATH:-$SCRATCH/release-signing.keychain-db}"

if [ "$ACTION" = delete ]; then
    if [ -e "$KEYCHAIN_PATH" ]; then
        security delete-keychain "$KEYCHAIN_PATH" >&2 || die "could not delete $KEYCHAIN_PATH"
        info "deleted $KEYCHAIN_PATH"
    else
        note "there is no $KEYCHAIN_PATH to delete"
    fi
    exit 0
fi

[ -n "${SIGNING_P12:-}" ] || die "SIGNING_P12 is empty" "It holds the .p12 file, base64-encoded."
[ -n "${SIGNING_P12_PASSWORD:-}" ] || die "SIGNING_P12_PASSWORD is empty" "It holds the password of the .p12 file."
[ ! -e "$KEYCHAIN_PATH" ] || die "$KEYCHAIN_PATH already exists" "Run scripts/ci-keychain.sh delete first."

WORK="$(mktemp -d "$SCRATCH/ci-keychain.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
CERTIFICATE="$WORK/certificate.p12"
printf '%s' "$SIGNING_P12" | base64 --decode >"$CERTIFICATE" 2>/dev/null || : >"$CERTIFICATE"
# base64 skips what it cannot read, so the result is what gets checked. A .p12 file starts with the byte 0x30.
[ "$(head -c 1 "$CERTIFICATE" | od -An -tx1 | tr -d ' \n')" = 30 ] ||
    die "SIGNING_P12 does not decode to a .p12 file" "Encode the file again: base64 -i certificate.p12"

# Nobody needs this password again. The keychain stays unlocked for the job, and the job deletes it.
KEYCHAIN_PASSWORD="$(/usr/bin/openssl rand -hex 20)" || die "could not make a password for the keychain"
[ "${#KEYCHAIN_PASSWORD}" -eq 40 ] || die "could not make a password for the keychain"

step "Making $KEYCHAIN_PATH"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >&2 || die "could not create the keychain"
# Six hours before it locks itself. A notarization can take a while, and no job runs that long.
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH" >&2 || die "could not change the keychain's settings"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >&2 || die "could not unlock the keychain"

step "Importing the certificate"
# -x: the key cannot be exported from this keychain. -T: codesign is the only program that may use it.
security import "$CERTIFICATE" -k "$KEYCHAIN_PATH" -f pkcs12 -P "$SIGNING_P12_PASSWORD" -x \
    -T /usr/bin/codesign >/dev/null ||
    die "could not import the certificate" "Check SIGNING_P12_PASSWORD, and that the .p12 holds the certificate and its private key."
# Without this, codesign waits for someone to click Allow in a dialog that no runner shows.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null ||
    die "could not let codesign use the key"

# First in the search list, with whatever was there after it.
EXISTING=()
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line#\"}"
    line="${line%\"}"
    [ -z "$line" ] || [ "$line" = "$KEYCHAIN_PATH" ] || EXISTING+=("$line")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$KEYCHAIN_PATH" ${EXISTING[@]+"${EXISTING[@]}"} >&2 ||
    die "could not add the keychain to the search list"
security default-keychain -d user -s "$KEYCHAIN_PATH" >&2 || die "could not make it the default keychain"

info "keychain: $KEYCHAIN_PATH"
printf '%s\n' "$KEYCHAIN_PATH"
