#!/bin/bash
# Redraws what gives the disk image's Finder window its look: the picture behind the icons and
# Finder's layout file. Run with --help for the options.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
    cat <<EOF
Usage: scripts/make-dmg-art.sh [options]

Makes these two files in Resources/dmg/, replacing the ones there:

  background.tiff   the picture behind the icons, at 1x and 2x: the config's banner, a card for
                    each icon, an arrow between them and the narrator with their first line
  DS_Store          Finder's layout file: the window's size, the icon size and where the icons sit

scripts/make-dmg.sh copies both into every disk image, so commit them. Run this again after you
change the banner or the narrator in the config, the app's name in scripts/common.sh, or the
layout in Sources/ShawnUI/Views/DiskImageBackground.swift.

The app draws the picture with its own views, offscreen, with --no-remote and a throwaway
--sandbox in a temporary folder. No window opens. scripts/make-dsstore.py writes the layout file
from the numbers the app prints, without Finder and without mounting anything.

  --config DIR   the config whose banner and narrator to draw   [CONFIG_DIR, default config/]
  --no-build     use the app that swift build made last instead of building it
  -h, --help     show this help

Needs Python 3 with the ds_store and mac_alias packages. PYTHON names the interpreter (default
python3).
EOF
}

CONFIG_DIR="${CONFIG_DIR:-$INSTALLER_ROOT/config}"
PYTHON="${PYTHON:-python3}"
BUILD=1

while [ $# -gt 0 ]; do
    case "$1" in
        --config) [ $# -ge 2 ] || die "$1 needs a value"; CONFIG_DIR="$2"; shift 2 ;;
        --no-build) BUILD=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" "Run scripts/make-dmg-art.sh --help for the options." ;;
    esac
done

CONFIG_DIR="$(absolute_path "$CONFIG_DIR")"
[ -f "$CONFIG_DIR/installer.yaml" ] || die "no installer.yaml in $CONFIG_DIR" "Point --config at a config folder."
OUTPUT_DIR="$DMG_ART_DIR"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/make-dmg-art.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
# Python puts the current folder first on its import path for -c, so run from one that holds
# nothing but this script's own files.
cd "$WORK"

PYTHON_PATH="$(command -v "$PYTHON")" ||
    die "cannot find $PYTHON" "Install Python 3 with ds_store and mac_alias, or set PYTHON to one that has them."
"$PYTHON" -c 'import ds_store, mac_alias' 2>/dev/null ||
    die "ds_store and mac_alias are not both installed for $PYTHON_PATH" \
        "Install them with: $PYTHON -m pip install ds_store mac_alias" \
        "Or set PYTHON to a Python 3 that has them."

if [ "$BUILD" = 1 ]; then
    step "Building the app"
    swift build --package-path "$INSTALLER_ROOT" --product "$APP_EXECUTABLE" >&2
fi
APP="$(swift build --package-path "$INSTALLER_ROOT" --show-bin-path)/$APP_EXECUTABLE"
[ -x "$APP" ] || die "no app at $APP" "Build it first: swift build --product $APP_EXECUTABLE"

mkdir -p "$WORK/home" "$WORK/tmp" "$WORK/out"
# Whatever the app or Python put in a temporary folder goes when $WORK goes. (swift build keeps the
# caller's, where it shares its lock files with any other build of this package.)
export TMPDIR="$WORK/tmp"

step "Drawing the picture at 1x and 2x"
for scale in 1 2; do
    # The app's home folder is $WORK/home (CFFIXED_USER_HOME moves it; HOME is for anything it starts).
    CFFIXED_USER_HOME="$WORK/home" HOME="$WORK/home" "$APP" --config "$CONFIG_DIR" --no-remote \
        --sandbox "$WORK/sandbox" --disk-image-art "$WORK/out/background@${scale}x.png" \
        --snapshot-scale "$scale" >"$WORK/out/art@${scale}x.out" ||
        die "the app could not draw the picture at ${scale}x"
done

# The app prints "layout window=680x460 title-bar=28 icon=128 …": one name=value for each number.
LAYOUT="$(sed -n 's/^layout //p' "$WORK/out/art@1x.out" | head -n 1)"
[ -n "$LAYOUT" ] || die "the app did not print the window's layout"
layout_value() { # <name>
    local word
    for word in $LAYOUT; do
        case "$word" in "$1="*) printf '%s\n' "${word#*=}"; return 0 ;; esac
    done
    die "the app's layout line has no $1" "It printed: layout $LAYOUT"
}
WINDOW="$(layout_value window)"
TITLE_BAR="$(layout_value title-bar)"
ICON_SIZE="$(layout_value icon)"
TEXT_SIZE="$(layout_value text)"
APP_AT="$(layout_value app)"
APPLICATIONS_AT="$(layout_value applications)"
BACKGROUND="$(layout_value background)"

# One file with both sizes. Finder takes the one that fits the display.
tiffutil -cathidpicheck "$WORK/out/background@1x.png" "$WORK/out/background@2x.png" \
    -out "$WORK/out/background.tiff" >/dev/null 2>&1 || die "tiffutil could not join the two pictures"

step "Writing Finder's layout file"
"$PYTHON" "$INSTALLER_ROOT/scripts/make-dsstore.py" --volume "$APP_NAME" --app "$APP_BUNDLE_NAME" \
    --picture "$DMG_PICTURE_NAME" --window "$WINDOW" --title-bar "$TITLE_BAR" --icon-size "$ICON_SIZE" \
    --text-size "$TEXT_SIZE" --app-at "$APP_AT" --applications-at "$APPLICATIONS_AT" \
    --background "$BACKGROUND" "$WORK/out/DS_Store" || die "could not write the layout file"

mkdir -p "$OUTPUT_DIR"
for file in background.tiff DS_Store; do
    mv -f "$WORK/out/$file" "$OUTPUT_DIR/$file"
    info "$(printf '%-16s %s' "$file" "$(file_size "$OUTPUT_DIR/$file")")"
done
info "window:          $WINDOW points under a $TITLE_BAR point title bar"
info "icons:           $APP_BUNDLE_NAME at $APP_AT, Applications at $APPLICATIONS_AT"
printf '%s\n' "$OUTPUT_DIR"
