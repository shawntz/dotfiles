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

Needs the ds_store and mac_alias packages. scripts/make-dmg-art.sh prints a way to get them in a
virtual environment.
"""

import argparse
import datetime
import os
import re
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


def number(text, what, least=0):
    """A whole number of points. Five digits is more than any screen, and it keeps every value inside
    the four bytes the layout file gives a position."""
    if not re.fullmatch(r"[0-9]{1,5}", text) or int(text) < least:
        fail(f"{what} must be a whole number from {least} to 99999, not {text!r}")
    return int(text)


def pair(text, separator, what, least=0):
    parts = text.lower().split(separator)
    if len(parts) != 2:
        fail(f"{what} must be two whole numbers with {separator!r} between them, not {text!r}")
    return number(parts[0], what, least), number(parts[1], what, least)


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
        fail(f"{error}. scripts/make-dmg-art.sh prints a way to get ds_store and mac_alias in a virtual environment.")

    width, height = pair(options.window, "x", "--window", least=1)
    title_bar = number(options.title_bar, "--title-bar")
    icon_size = number(options.icon_size, "--icon-size", least=1)
    text_size = number(options.text_size, "--text-size", least=1)
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
        "WindowBounds": "{{%d, %d}, {%d, %d}}" % (*WINDOW_ORIGIN, width, height + title_bar),
    }
    icons = {
        "viewOptionsVersion": 1,
        "arrangeBy": "none",
        # 2 is a picture. The three color keys go with every background type, and here they hold the
        # window's own background color.
        "backgroundType": 2,
        "backgroundImageAlias": picture_alias(options.volume.encode(), options.picture.encode()),
        "backgroundColorRed": red,
        "backgroundColorGreen": green,
        "backgroundColorBlue": blue,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 100.0,
        "iconSize": float(icon_size),
        "labelOnBottom": True,
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
        "showIconPreview": False,
        "showItemInfo": False,
        "textSize": float(text_size),
    }

    # Written beside OUTPUT and moved onto it once it reads back right, so a run that fails leaves
    # the file that was there.
    draft = options.output + ".new"
    try:
        if os.path.exists(draft):
            os.remove(draft)
        with DSStore.open(draft, "w+") as store:
            store["."]["vSrn"] = ("long", 1)
            store["."]["bwsp"] = window
            store["."]["icvp"] = icons
            store["."]["icvl"] = (b"type", b"icnv")
            store[options.app]["Iloc"] = app_at
            store["Applications"]["Iloc"] = applications_at
            store[options.picture]["Iloc"] = (app_at[0], height + HIDDEN_ICON_DROP)
            store[CHANGE_LOG_FOLDER]["Iloc"] = (applications_at[0], height + HIDDEN_ICON_DROP)

        # Read it back: a layout file that this cannot read is one Finder cannot read either.
        with DSStore.open(draft, "r") as store:
            found = {(entry.filename, entry.code.decode()): entry.value for entry in store}
        for name, at in ((options.app, app_at), ("Applications", applications_at)):
            if tuple(found.get((name, "Iloc"), ())[:2]) != at:
                fail(f"the layout file does not place {name} at {at}")
        if found.get((".", "bwsp"), {}).get("WindowBounds") != window["WindowBounds"]:
            fail("the layout file does not hold the window's size")
        os.replace(draft, options.output)
    finally:
        if os.path.exists(draft):
            os.remove(draft)


if __name__ == "__main__":
    main()
