#!/usr/bin/env python3
"""Writes Finder's layout file for the disk image's window. scripts/make-dmg-art.sh runs it.

Usage: make-dsstore.py --volume NAME --app NAME.app --picture NAME --window WxH --title-bar N
                       --icon-size N --text-size N --app-at X,Y --applications-at X,Y
                       --background RRGGBB OUTPUT

Finder keeps what a folder's window looks like in a file named .DS_Store inside that folder: the
window's size, the icon size, where each icon sits and which picture is behind them. This writes
that file for the top folder of the disk image. It asks Finder nothing and mounts nothing, and the
same options always give the same bytes.

Sizes and positions are in points. --window is the window under its title bar, and the positions
are the centers of the two icons, counted from that area's top left corner.

Finder finds the picture through an alias record: the volume's name, the folder's id, the file's
name and the file's id. The picture is in the top folder, whose id is 2 on every HFS+ volume, so
its folder and name are enough. The file's own id differs from one image to the next, so the
record holds none.

Needs the ds_store and mac_alias packages (python3 -m pip install ds_store mac_alias).
"""

import argparse
import datetime
import os
import sys

USAGE = __doc__.split("\n\n")[1]

# The id of the top folder of every HFS+ volume.
ROOT_FOLDER_ID = 2
# Where the window's bottom left corner goes, from the screen's bottom left corner. Finder moves
# the window when that leaves part of it off screen.
WINDOW_ORIGIN = (200, 280)
# Finder shows two more icons to someone who has turned hidden files on: the picture, and the
# folder macOS keeps its log of changes in when the build's short mount leaves one. They go this
# far under the window, where they cover nothing.
HIDDEN_ICON_DROP = 200
CHANGE_LOG_FOLDER = ".fseventsd"


def fail(message):
    print(f"make-dsstore.py: {message}", file=sys.stderr)
    sys.exit(1)


def pair(text, separator, what):
    parts = text.lower().split(separator)
    if len(parts) != 2 or not all(part.isdigit() for part in parts):
        fail(f"{what} must be two whole numbers with {separator!r} between them, not {text!r}")
    return int(parts[0]), int(parts[1])


def color(text):
    if len(text) != 6 or any(character not in "0123456789abcdefABCDEF" for character in text):
        fail(f"--background must be six hex digits such as 110A1C, not {text!r}")
    return tuple(int(text[index:index + 2], 16) / 255 for index in (0, 2, 4))


def picture_alias(volume, picture):
    """The alias record Finder follows to the picture, as mac_alias writes one for a real file."""
    from mac_alias import ALIAS_FIXED_DISK, ALIAS_KIND_FILE, ALIAS_NO_CNID, Alias
    from mac_alias.alias import TargetInfo, VolumeInfo
    from mac_alias.utils import mac_epoch

    # The dates are not the image's: every image gets new ones. Finder matches the volume by name.
    date = mac_epoch + datetime.timedelta(days=36525)
    alias = Alias()
    alias.volume = VolumeInfo(volume, date, b"H+", ALIAS_FIXED_DISK, 0, b"\0\0")
    alias.volume.posix_path = b"/Volumes/" + volume
    alias.target = TargetInfo(ALIAS_KIND_FILE, picture, ROOT_FOLDER_ID, ALIAS_NO_CNID, date,
                              b"\0\0\0\0", b"\0\0\0\0")
    alias.target.folder_name = volume
    alias.target.cnid_path = []
    alias.target.carbon_path = volume + b":" + picture
    alias.target.posix_path = b"/" + picture
    return alias.to_bytes()


def main():
    parser = argparse.ArgumentParser(usage=USAGE, add_help=False)
    parser.add_argument("-h", "--help", action="store_true")
    for name in ("volume", "app", "picture", "window", "title-bar", "icon-size", "text-size",
                 "app-at", "applications-at", "background"):
        parser.add_argument(f"--{name}")
    parser.add_argument("output", nargs="?")
    options = parser.parse_args()
    if options.help:
        print(__doc__.strip())
        return
    missing = [name for name, value in vars(options).items() if value is None]
    if missing:
        fail("missing " + ", ".join("OUTPUT" if name == "output" else "--" + name.replace("_", "-")
                                    for name in missing) + f"\n{USAGE}")

    try:
        from ds_store import DSStore
        import mac_alias  # noqa: F401
    except ImportError as error:
        fail(f"{error}. Install both with: {os.path.basename(sys.executable)} -m pip install ds_store mac_alias")

    width, height = pair(options.window, "x", "--window")
    for name in ("title_bar", "icon_size", "text_size"):
        if not getattr(options, name).isdigit():
            fail(f"--{name.replace('_', '-')} must be a whole number, not {getattr(options, name)!r}")
    app_at = pair(options.app_at, ",", "--app-at")
    applications_at = pair(options.applications_at, ",", "--applications-at")
    red, green, blue = color(options.background)
    for name in (options.volume, options.app, options.picture):
        if not name or "/" in name or ":" in name:
            fail(f"{name!r} is not a file or volume name")
    if not options.picture.startswith("."):
        fail(f"--picture must start with a period, so that Finder hides it, and {options.picture!r} does not")

    window = {
        "ContainerShowSidebar": False,
        "PreviewPaneVisibility": False,
        "ShowPathbar": False,
        "ShowSidebar": False,
        "ShowStatusBar": False,
        "ShowTabView": False,
        "ShowToolbar": False,
        "SidebarWidth": 180,
        "WindowBounds": "{{%d, %d}, {%d, %d}}" % (*WINDOW_ORIGIN, width, height + int(options.title_bar)),
    }
    icons = {
        "viewOptionsVersion": 1,
        "arrangeBy": "none",
        # Finder reads the picture, and keeps the color for a window whose picture it cannot find.
        "backgroundType": 2,
        "backgroundImageAlias": picture_alias(options.volume.encode(), options.picture.encode()),
        "backgroundColorRed": red,
        "backgroundColorGreen": green,
        "backgroundColorBlue": blue,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 100.0,
        "iconSize": float(options.icon_size),
        "labelOnBottom": True,
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
        "showIconPreview": False,
        "showItemInfo": False,
        "textSize": float(options.text_size),
    }

    if os.path.exists(options.output):
        os.remove(options.output)
    with DSStore.open(options.output, "w+") as store:
        store["."]["vSrn"] = ("long", 1)
        store["."]["bwsp"] = window
        store["."]["icvp"] = icons
        store["."]["icvl"] = (b"type", b"icnv")
        store[options.app]["Iloc"] = app_at
        store["Applications"]["Iloc"] = applications_at
        store[options.picture]["Iloc"] = (app_at[0], height + HIDDEN_ICON_DROP)
        store[CHANGE_LOG_FOLDER]["Iloc"] = (applications_at[0], height + HIDDEN_ICON_DROP)

    # Read it back: a layout file that this cannot read is one Finder cannot read either.
    with DSStore.open(options.output, "r") as store:
        found = {(entry.filename, entry.code.decode()): entry.value for entry in store}
    for name, at in ((options.app, app_at), ("Applications", applications_at)):
        if tuple(found.get((name, "Iloc"), ())[:2]) != at:
            fail(f"wrote {options.output}, and it does not place {name} at {at}")
    if found.get((".", "bwsp"), {}).get("WindowBounds") != window["WindowBounds"]:
        fail(f"wrote {options.output}, and it does not hold the window's size")


if __name__ == "__main__":
    main()
