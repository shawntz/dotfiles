#!/bin/bash
# Builds "Shawn's Dotfiles.app": the installer app, with the shawn CLI and the web-app shell
# inside it and the YAML config bundled. Run with --help for the options.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
    cat <<EOF
Usage: scripts/build-app.sh [options]

Builds "$APP_BUNDLE_NAME" with swift build, bundles config/, signs it and checks the signature.
Works from any directory. Every option can also be set with the environment variable shown.

  -c, --configuration NAME  release or debug                          [CONFIGURATION, default release]
  -a, --archs "LIST"        arm64, x86_64, or "arm64 x86_64" for a universal app
                                                                      [ARCHS, default arm64]
  -s, --sign IDENTITY       codesign identity (name or SHA-1); "-" signs ad hoc
                                                                      [SIGN_IDENTITY, default: auto]
  -o, --output DIR          where the app goes                        [OUTPUT_DIR, default build/]
      --config DIR          config directory to bundle                [CONFIG_DIR, default config/]
      --print-identity      print the identity that would be used, then exit
  -h, --help                show this help

The version comes from ShawnCore.version in Sources/ShawnCore/ShawnCore.swift. BUILD_NUMBER
sets CFBundleVersion (default: the version).

Contents/Resources/build-info.json records {version, commit, sourceTree}: the git commit and the
committed sources the build came from, which the installer hands to the shawn CLI for its
self-update. sourceTree is empty when Sources/ or Package.* have uncommitted or untracked
changes, when they change during the build, or outside a git checkout.

Signing: with SIGN_IDENTITY unset, the first "Developer ID Application" identity in your
keychain is used; without one the app is signed ad hoc, which runs on this Mac but is blocked
by Gatekeeper on others. Helpers are signed before the app, all with the hardened runtime; a
secure timestamp is added only for a real identity.

Examples:
  scripts/build-app.sh                              # release, arm64, auto identity
  SIGN_IDENTITY=- scripts/build-app.sh              # ad hoc
  scripts/build-app.sh --archs "arm64 x86_64"       # universal
EOF
}

CONFIGURATION="${CONFIGURATION:-release}"
ARCHS="${ARCHS:-arm64}"
OUTPUT_DIR="${OUTPUT_DIR:-$INSTALLER_ROOT/build}"
CONFIG_DIR="${CONFIG_DIR:-$INSTALLER_ROOT/config}"
PRINT_IDENTITY=0

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--configuration) [ $# -ge 2 ] || die "$1 needs a value"; CONFIGURATION="$2"; shift 2 ;;
        -a|--archs) [ $# -ge 2 ] || die "$1 needs a value"; ARCHS="$2"; shift 2 ;;
        -s|--sign) [ $# -ge 2 ] || die "$1 needs a value"; SIGN_IDENTITY="$2"; shift 2 ;;
        -o|--output) [ $# -ge 2 ] || die "$1 needs a value"; OUTPUT_DIR="$2"; shift 2 ;;
        --config) [ $# -ge 2 ] || die "$1 needs a value"; CONFIG_DIR="$2"; shift 2 ;;
        --print-identity) PRINT_IDENTITY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" "Run scripts/build-app.sh --help for the options." ;;
    esac
done

resolve_identity
if [ "$PRINT_IDENTITY" = 1 ]; then
    printf '%s\t%s\n' "$SIGN_ID" "$SIGN_LABEL"
    exit 0
fi

case "$CONFIGURATION" in
    release|debug) ;;
    *) die "configuration must be release or debug, not \"$CONFIGURATION\"" ;;
esac

ARCH_LIST=()
for arch in $ARCHS; do
    case "$arch" in
        arm64|x86_64) ARCH_LIST+=("$arch") ;;
        *) die "unsupported architecture \"$arch\"" "Use arm64, x86_64, or \"arm64 x86_64\"." ;;
    esac
done
[ ${#ARCH_LIST[@]} -gt 0 ] || die "ARCHS is empty" "Use arm64, x86_64, or \"arm64 x86_64\"."

OUTPUT_DIR="$(absolute_path "$OUTPUT_DIR")"
CONFIG_DIR="$(absolute_path "$CONFIG_DIR")"
[ -f "$CONFIG_DIR/installer.yaml" ] || die "no installer.yaml in $CONFIG_DIR" \
    "The app needs a config to bundle. Pass --config DIR (or CONFIG_DIR) to use another directory."

VERSION="$(read_version)"
BUILD_NUMBER="${BUILD_NUMBER:-$VERSION}"
printf '%s' "$BUILD_NUMBER" | grep -Eq '^[0-9]+(\.[0-9]+){0,2}$' ||
    die "BUILD_NUMBER \"$BUILD_NUMBER\" is not of the form 123 or 1.2.3" "CFBundleVersion only accepts numbers."
PRODUCTS=("$APP_EXECUTABLE" shawn WebAppShell)

cd "$INSTALLER_ROOT"
mkdir -p "$OUTPUT_DIR"
STAGE="$(mktemp -d "$OUTPUT_DIR/.build-app.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

# MARK: Provenance

# Which committed sources the binaries come from, for build-info.json. Read before compiling and
# again after, so an edit made while swift build runs leaves the record empty (unknown) rather than
# naming sources the binary may not match.
source_provenance
BUILT_FROM_TREE="$SOURCE_TREE"

# MARK: Compile

# SwiftPM's default build system writes every architecture to the same products folder, so each
# architecture's binaries are copied aside before the next build replaces them.
BIN_DIRS=()
for arch in "${ARCH_LIST[@]}"; do
    step "Building $CONFIGURATION for $arch"
    # Progress and compiler errors go to stderr; stdout is only the finished app's path.
    swift build -c "$CONFIGURATION" --arch "$arch" >&2
    bin_dir="$(swift build -c "$CONFIGURATION" --arch "$arch" --show-bin-path)"
    # SwiftPM resource bundles would be looked up next to the .app, which breaks signing; the
    # package keeps its runtime files in config/ instead, so refuse rather than ship a broken app.
    for bundle in "$bin_dir"/*.bundle; do
        [ -e "$bundle" ] || continue
        die "found the SwiftPM resource bundle $(basename "$bundle")" \
            "build-app.sh does not package target resources. Keep runtime files under config/."
    done
    mkdir -p "$STAGE/products/$arch"
    for product in "${PRODUCTS[@]}"; do
        [ -x "$bin_dir/$product" ] || die "swift build finished but $bin_dir/$product is missing"
        [ "$(lipo -archs "$bin_dir/$product")" = "$arch" ] ||
            die "$bin_dir/$product is $(lipo -archs "$bin_dir/$product"), not $arch"
        cp "$bin_dir/$product" "$STAGE/products/$arch/$product"
    done
    BIN_DIRS+=("$STAGE/products/$arch")
done

source_provenance
[ "$SOURCE_TREE" = "$BUILT_FROM_TREE" ] || SOURCE_TREE=""
# MARK: Icon

ICON="$INSTALLER_ROOT/Resources/AppIcon.icns"
ICON_SCRIPT="$INSTALLER_ROOT/scripts/make-icon.swift"
if [ ! -f "$ICON" ] || [ "$ICON_SCRIPT" -nt "$ICON" ]; then
    step "Drawing the app icon"
    swift "$ICON_SCRIPT" "$ICON" >/dev/null
fi

# MARK: Assemble

APP="$STAGE/$APP_BUNDLE_NAME"

step "Assembling $APP_BUNDLE_NAME $VERSION"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"

place_binary() { # <product> <destination>
    local product="$1" destination="$2" inputs=() dir
    for dir in "${BIN_DIRS[@]}"; do inputs+=("$dir/$product"); done
    if [ ${#inputs[@]} -eq 1 ]; then
        cp "${inputs[0]}" "$destination"
    else
        lipo -create -output "$destination" "${inputs[@]}"
    fi
    chmod 0755 "$destination"
    local have want
    have="$(lipo -archs "$destination" | tr ' ' '\n' | sort | tr '\n' ' ')"
    want="$(printf '%s\n' "${ARCH_LIST[@]}" | sort | tr '\n' ' ')"
    [ "$have" = "$want" ] || die "$product has architectures \"$have\", expected \"$want\""
}
place_binary "$APP_EXECUTABLE" "$APP/Contents/MacOS/$APP_EXECUTABLE"
place_binary shawn "$APP/Contents/Helpers/shawn"
place_binary WebAppShell "$APP/Contents/Helpers/WebAppShell"

ditto --norsrc --noextattr --noacl "$CONFIG_DIR" "$APP/Contents/Resources/config"
find "$APP/Contents/Resources/config" -name .DS_Store -delete
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
# The shawn-cli item copies this into ~/.shawn/state/cli.json, so the CLI knows which sources the
# installed binary came from. It is written before signing: the signature seals Resources.
write_build_info "$APP/Contents/Resources/build-info.json" "$VERSION"

PLIST="$APP/Contents/Info.plist"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@BUILD@/$BUILD_NUMBER/g" "$INSTALLER_ROOT/Resources/Info.plist" >"$PLIST"
# Canonical XML drops the template's comment, so any token still present is a real leftover.
plutil -convert xml1 "$PLIST"
if grep -q '@[A-Z_]*@' "$PLIST"; then
    die "Resources/Info.plist has a token build-app.sh does not fill in: $(grep -o '@[A-Z_]*@' "$PLIST" | head -n 1)"
fi
plutil -lint -s "$PLIST" || die "the generated Info.plist is not valid"

# Extended attributes (quarantine, Finder info) make codesign refuse the bundle.
xattr -cr "$APP"

# MARK: Sign (inside out: helpers, then the app)

step "Signing with $SIGN_LABEL ($SIGN_SOURCE)"
if is_ad_hoc && [ -z "${SIGN_IDENTITY:-}" ]; then
    warn "no \"Developer ID Application\" identity found, so the app is signed ad hoc."
    note "It runs on this Mac; Gatekeeper blocks it on others. Set SIGN_IDENTITY to choose an identity."
fi
set_codesign_flags
sign() { # <label> <codesign arguments...>; codesign's chatter is shown only when it fails
    local label="$1" output
    shift
    if ! output="$(codesign "${CODESIGN_FLAGS[@]}" "$@" 2>&1)"; then
        printf '%s\n' "$output" >&2
        die "could not sign $label with $SIGN_LABEL" \
            "Check the identity with: security find-identity -v -p codesigning"
    fi
    info "signed $label"
}
sign "Helpers/shawn" --identifier "$APP_BUNDLE_ID.shawn" "$APP/Contents/Helpers/shawn"
sign "Helpers/WebAppShell" --identifier "$APP_BUNDLE_ID.WebAppShell" "$APP/Contents/Helpers/WebAppShell"
sign "$APP_BUNDLE_NAME" "$APP"

# MARK: Install and verify

FINAL="$OUTPUT_DIR/$APP_BUNDLE_NAME"
rm -rf "$FINAL"
mv "$APP" "$FINAL"

step "Verifying"
codesign --verify --deep --strict "$FINAL" || die "codesign could not verify $FINAL"
for helper in shawn WebAppShell; do
    codesign --verify --strict "$FINAL/Contents/Helpers/$helper" || die "codesign could not verify the $helper helper"
done

details="$(codesign -dvv "$FINAL" 2>&1)"
info "app:        $FINAL"
info "version:    $VERSION ($CONFIGURATION, $(lipo -archs "$FINAL/Contents/MacOS/$APP_EXECUTABLE"))"
info "identifier: $(printf '%s\n' "$details" | sed -n 's/^Identifier=//p')"
info "signature:  $(signing_authority "$FINAL")"
team="$(printf '%s\n' "$details" | sed -n 's/^TeamIdentifier=//p')"
[ -z "$team" ] || [ "$team" = "not set" ] || info "team:       $team"
flags="$(printf '%s\n' "$details" | sed -n 's/^CodeDirectory .*flags=\([^ ]*\).*/\1/p')"
[ -z "$flags" ] || info "flags:      $flags"
if [ -n "$SOURCE_TREE" ]; then
    info "sources:    committed at ${SOURCE_COMMIT:0:12} (recorded in build-info.json)"
elif [ "$SOURCE_GIT" = 0 ]; then
    info "sources:    not a git checkout, so build-info.json records no source tree"
elif [ -z "$SOURCE_COMMIT" ]; then
    info "sources:    no commit yet, so build-info.json records no source tree"
elif [ -n "$SOURCE_CHANGES" ]; then
    info "sources:    uncommitted changes in Sources/ or Package.*, so build-info.json records no source tree"
else
    info "sources:    changed during the build, so build-info.json records no source tree"
fi
printf '%s\n' "$FINAL"
