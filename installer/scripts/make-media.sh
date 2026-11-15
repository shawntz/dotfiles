#!/bin/bash
# Makes the README's animations and stills of the installer window from the app's own screens,
# rendered offscreen. Run with --help for the options.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
    cat <<EOF
Usage: scripts/make-media.sh [options] OUTPUT_DIR

Makes these files in OUTPUT_DIR, replacing any already there:

  tour.gif       the welcome screen, a whole run as a time-lapse with the sheets it brings up,
                 then the finished screen
  sheets.gif     each screen where the app asks or tells you something, one after another
  welcome.png    the welcome screen at 2x
  finished.png   the finished screen at 2x
  icon-256.png   the app icon, 256 pixels square
  icon-512.png   the app icon, 512 pixels square

Every frame is a --snapshot of the app's SwiftUI views, rendered offscreen with --no-remote and a
throwaway --sandbox in a temporary folder. No window opens and nothing records the screen. The app
sees the temporary folder as its home folder, so the header reads "config: ~/$SHOWN_CONFIG".

  --config DIR   the config to show                [CONFIG_DIR, default config/]
  --no-build     use the app that swift build made last instead of building it
  -h, --help     show this help

Needs Python 3 with Pillow. PYTHON names the interpreter (default python3).
EOF
}

# Where the config appears to be, under the stand-in home folder.
SHOWN_CONFIG="Developer/dotfiles/installer/config"
# Window size in points. 960x640 is the smallest the window gets, so its text is the largest a
# README column shows.
SIZE="960x640"
# The GIFs are rendered at 2x and reduced to GIF_SIZE by make-gif.py. A README column is about 830
# pixels wide, which a 2x display draws with 1660, and there a 1x render looks soft.
GIF_SCALE=2
GIF_SIZE="1440x960"
# The run: evenly spaced points from 0 to 1. The app gives every step at least one of them while
# the config has at most (RUN_FRAMES - 1) / 2 steps.
RUN_FRAMES=45
RUN_FRAME_MS=150
# Sheets the tour shows when its run reaches them, one "STATE WHERE MS" per line. STATE is a snapshot
# state (see the app's --help). WHERE is how far through the run (0 to 1), an item kind (the run as
# the first item of that kind starts), or - for a screen that is not part of a run, which shows
# before the run starts. MS is how long it stays. A sheet goes before the run frame at the same
# point, and sheets at the same point keep this order.
TOUR_SHEETS=(
    "ask - 1400"
    "password 0 1200"
    "attention github 1500"
)
# The screens sheets.gif shows, in order, one "STATE WHERE" per line, WHERE as above.
SHEETS=(
    "customize -"
    "ask -"
    "password 0"
    "question mas"
    "attention github"
    "dry-run-finished -"
)
SHEET_MS=2000

CONFIG_DIR="${CONFIG_DIR:-$INSTALLER_ROOT/config}"
PYTHON="${PYTHON:-python3}"
BUILD=1
OUTPUT_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --config) [ $# -ge 2 ] || die "$1 needs a value"; CONFIG_DIR="$2"; shift 2 ;;
        --no-build) BUILD=0; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $1" "Run scripts/make-media.sh --help for the options." ;;
        *) [ -z "$OUTPUT_DIR" ] || die "give one OUTPUT_DIR, not \"$OUTPUT_DIR\" and \"$1\""; OUTPUT_DIR="$1"; shift ;;
    esac
done

[ -n "$OUTPUT_DIR" ] || die "say where the files go" "Usage: scripts/make-media.sh [options] OUTPUT_DIR"
OUTPUT_DIR="$(absolute_path "$OUTPUT_DIR")"
CONFIG_DIR="$(absolute_path "$CONFIG_DIR")"
[ -f "$CONFIG_DIR/installer.yaml" ] || die "no installer.yaml in $CONFIG_DIR" "Point --config at a config folder."
ICON="$INSTALLER_ROOT/Resources/AppIcon.icns"
[ -f "$ICON" ] || die "cannot find $ICON"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/make-media.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
# Python puts the current folder first on its import path for -c and stdin, so run from one that
# holds nothing but this script's own files.
cd "$WORK"

PYTHON_PATH="$(command -v "$PYTHON")" ||
    die "cannot find $PYTHON" "Install Python 3 with Pillow, or set PYTHON to one that has it."
"$PYTHON" -c 'import PIL' 2>/dev/null ||
    die "Pillow is not installed for $PYTHON_PATH" \
        "Install it with: $PYTHON -m pip install Pillow" \
        "Or set PYTHON to a Python 3 that has it, e.g. PYTHON=/opt/homebrew/bin/python3."

if [ "$BUILD" = 1 ]; then
    step "Building the app"
    swift build --package-path "$INSTALLER_ROOT" --product "$APP_EXECUTABLE" >&2
fi
APP="$(swift build --package-path "$INSTALLER_ROOT" --show-bin-path)/$APP_EXECUTABLE"
[ -x "$APP" ] || die "no app at $APP" "Build it first: swift build --product $APP_EXECUTABLE"

FRAMES="$WORK/frames"
mkdir -p "$FRAMES" "$WORK/out" "$WORK/tmp" "$WORK/home/$(dirname "$SHOWN_CONFIG")"
# Whatever the app, Python or sips put in a temporary folder goes when $WORK goes. (swift build keeps
# the caller's, where it shares its lock files with any other build of this package.)
export TMPDIR="$WORK/tmp"
ditto "$CONFIG_DIR" "$WORK/home/$SHOWN_CONFIG"

# Renders one screen to $FRAMES/<name>.png. The app's home folder is $WORK/home (CFFIXED_USER_HOME
# moves it; HOME is for anything it starts), and the machine it would act on is $WORK/sandbox. What the
# app prints goes to $FRAMES/<name>.out.
render() { # <name> <scale> <state> [more app flags]
    local name="$1" scale="$2" state="$3"
    shift 3
    CFFIXED_USER_HOME="$WORK/home" HOME="$WORK/home" "$APP" --config "$WORK/home/$SHOWN_CONFIG" --no-remote \
        --sandbox "$WORK/sandbox" --snapshot "$FRAMES/$name.png" --snapshot-state "$state" \
        --snapshot-size "$SIZE" --snapshot-scale "$scale" ${1+"$@"} >"$FRAMES/$name.out" ||
        die "the app could not render the $state screen ($name)"
}

# Renders <state> at <where> (a fraction, an item kind, or - for no point of a run) and prints the
# fraction of the run it shows (-1 for -).
render_at() { # <name> <state> <where>
    local name="$1" state="$2" where="$3"
    case "$where" in
        -) render "$name" "$GIF_SCALE" "$state"; echo -1; return ;;
        [0-9]*) render "$name" "$GIF_SCALE" "$state" --snapshot-progress "$where" ;;
        *) render "$name" "$GIF_SCALE" "$state" --snapshot-at-kind "$where" ;;
    esac
    awk '$1 == "progress" { print $2 }' "$FRAMES/$name.out"
}

gif() { # <file name> <frame@ms>...
    local name="$1"
    shift
    "$PYTHON" "$INSTALLER_ROOT/scripts/make-gif.py" --size "$GIF_SIZE" "$WORK/out/$name" "$@" >/dev/null ||
        die "could not make $name"
}

step "Rendering the tour: the welcome screen, $RUN_FRAMES points of a run, ${#TOUR_SHEETS[@]} sheets, the finished screen"
render welcome "$GIF_SCALE" welcome
render finished "$GIF_SCALE" finished
# One line per frame of the run, "fraction <tab> 0 for a sheet or 1 for a run frame <tab> order <tab> frame@ms",
# sorted into the order they show.
: >"$WORK/run"
i=0
for sheet in ${TOUR_SHEETS[@]+"${TOUR_SHEETS[@]}"}; do
    read -r state where ms <<<"$sheet"
    fraction="$(render_at "tour-sheet-$i" "$state" "$where")"
    [ -n "$fraction" ] || die "the app did not say where in the run the $state sheet ($where) is"
    printf '%s\t0\t%d\t%s\n' "$fraction" "$i" "$FRAMES/tour-sheet-$i.png@$ms" >>"$WORK/run"
    i=$((i + 1))
done
i=0
while [ "$i" -lt "$RUN_FRAMES" ]; do
    name="$(printf 'run-%02d' "$i")"
    fraction="$(awk -v i="$i" -v n="$RUN_FRAMES" 'BEGIN { printf "%.6f", i / (n - 1) }')"
    render "$name" "$GIF_SCALE" running --snapshot-progress "$fraction"
    printf '%s\t1\t%d\t%s\n' "$fraction" "$i" "$FRAMES/$name.png@$RUN_FRAME_MS" >>"$WORK/run"
    i=$((i + 1))
done
TOUR=("$FRAMES/welcome.png@1500")
while IFS= read -r frame; do TOUR+=("$frame"); done < <(sort -t "$(printf '\t')" -k1,1n -k2,2n -k3,3n "$WORK/run" | cut -f4)
# Hold the finished run a moment, so its full bar registers before the finished screen replaces it.
TOUR+=("$FRAMES/$name.png@600" "$FRAMES/finished.png@3000")
gif tour.gif "${TOUR[@]}"

step "Rendering the sheets"
SHEET_FRAMES=()
i=0
for sheet in "${SHEETS[@]}"; do
    read -r state where <<<"$sheet"
    render_at "sheet-$i" "$state" "$where" >/dev/null
    SHEET_FRAMES+=("$FRAMES/sheet-$i.png@$SHEET_MS")
    i=$((i + 1))
done
gif sheets.gif "${SHEET_FRAMES[@]}"

step "Rendering the stills at 2x"
render still-welcome 2 welcome
render still-finished 2 finished
cp "$FRAMES/still-welcome.png" "$WORK/out/welcome.png"
cp "$FRAMES/still-finished.png" "$WORK/out/finished.png"

step "Converting the app icon"
for pixels in 256 512; do
    sips -s format png -Z "$pixels" "$ICON" --out "$WORK/out/icon-$pixels.png" >/dev/null ||
        die "sips could not convert $ICON"
done
# The corners must be see-through and the middle drawn; a failed conversion gives neither.
"$PYTHON" - "$WORK/out/icon-256.png" "$WORK/out/icon-512.png" <<'EOF' || die "the converted icon is wrong"
import sys
from PIL import Image
for path in sys.argv[1:]:
    with Image.open(path) as icon:
        icon = icon.convert("RGBA")
        width, height = icon.size
        if icon.getpixel((0, 0))[3] != 0 or icon.getpixel((width // 2, height // 2))[3] != 255:
            sys.exit(f"{path}: the corner is not transparent or the middle is empty")
EOF

mkdir -p "$OUTPUT_DIR"
for file in "$WORK/out"/*; do
    mv -f "$file" "$OUTPUT_DIR/"
    info "$(printf '%-13s %s' "$(basename "$file")" "$(file_size "$OUTPUT_DIR/$(basename "$file")")")"
done
printf '%s\n' "$OUTPUT_DIR"
