#!/usr/bin/env python3
"""Joins PNG frames into a looping GIF. scripts/make-media.sh runs it for the README's animations.

Usage: make-gif.py [--size WxH] OUTPUT.gif FRAME.png@MS [FRAME.png@MS ...]

Each frame shows for MS milliseconds (20 or more; GIF counts in hundredths of a second).

With --size, each frame is first reduced to WxH pixels by averaging the pixels each new one covers
(a box filter), so a 2x render keeps sharper text than a 1x one. Lanczos is a little crisper, but its
faint halos add colours. The README's tour comes out at 5.9 MB with Lanczos and 3.9 MB with the box.

All frames share one palette of 255 colours, chosen from all of them (see shared_palette), and map
onto it without dithering, so the window's flat colours stay flat and nothing flickers from one frame
to the next. A frame that repeats the one before it only adds to that frame's time. Pillow then stores
each frame as the rectangle that changed, with the pixels inside it that did not change left
transparent.

Needs Pillow (python3 -m pip install Pillow).
"""

import sys

USAGE = "usage: make-gif.py [--size WxH] OUTPUT.gif FRAME.png@MS [FRAME.png@MS ...]"


def fail(message):
    print(f"make-gif.py: {message}", file=sys.stderr)
    sys.exit(1)


try:
    from PIL import Image, ImageChops, features
except ImportError:
    fail(f"Pillow is not installed for {sys.executable}. Install it with: {sys.executable} -m pip install Pillow")

# Index 255 stays out of the palette. Pillow uses it to mark the pixels a frame leaves as they were.
COLOURS = 255
# A colour the first half of the palette misses by more than this (0 to 255, as grey) gets a say in the second.
MISS = 5
# Pillow 12 renamed getdata; older versions only have that.
FLATTENED = getattr(Image.Image, "get_flattened_data", None) or Image.Image.getdata


def parse_frame(argument):
    path, separator, milliseconds = argument.rpartition("@")
    if not separator or not path or not milliseconds.isdigit() or int(milliseconds) < 20:
        fail(f"'{argument}' is not FRAME.png@MS with MS a whole number of milliseconds, 20 or more")
    return path, int(milliseconds)


def parse_size(text):
    width, separator, height = text.lower().partition("x")
    if not separator or not width.isdigit() or not height.isdigit() or int(width) < 1 or int(height) < 1:
        fail(f"--size '{text}' is not WIDTHxHEIGHT, e.g. 1440x960")
    return int(width), int(height)


def load_frames(arguments, size=None):
    """The frames as RGB images (reduced to `size` if given) with their times, a run of identical frames merged into one."""
    frames, durations = [], []
    for argument in arguments:
        path, milliseconds = parse_frame(argument)
        try:
            with Image.open(path) as source:
                image = source.convert("RGB")
        except OSError as error:
            fail(f"cannot read {path}: {error}")
        if size and image.size != size:
            image = image.resize(size, Image.Resampling.BOX)
        if frames and image.size != frames[0].size:
            fail(f"{path} is {image.size[0]}x{image.size[1]}, but the first frame is {frames[0].size[0]}x{frames[0].size[1]}")
        if frames and image.tobytes() == frames[-1].tobytes():
            durations[-1] += milliseconds
            continue
        frames.append(image)
        durations.append(milliseconds)
    return frames, durations


def palette_image(colours):
    """A palette image with exactly these colours, so mapping a frame onto it never uses index 255."""
    palette = Image.new("P", (1, 1))
    palette.putpalette(colours)
    return palette


def picture_of(pixels):
    """A picture holding these pixels, to choose a palette from."""
    width = min(1024, len(pixels))
    height = -(-len(pixels) // width)
    pixels = pixels + [pixels[-1]] * (width * height - len(pixels))
    picture = Image.new("RGB", (width, height))
    picture.putdata(pixels)
    return picture


def choose(picture, count):
    method = Image.Quantize.LIBIMAGEQUANT if features.check("libimagequant") else Image.Quantize.MEDIANCUT
    return picture.quantize(colors=count, method=method, dither=Image.Dither.NONE).getpalette()[: count * 3]


def shared_palette(frames):
    """One palette for every frame, chosen in two passes.

    The first half comes from every pixel of every frame, so the large areas (the background, panels,
    text) match closely. Small things that show in few frames, such as a step's character, lose that
    count. So the second half comes from the colours the first half matches badly.
    """
    width, height = frames[0].size
    stack = Image.new("RGB", (width, height * len(frames)))
    for index, frame in enumerate(frames):
        stack.paste(frame, (0, index * height))
    first = choose(stack, COLOURS // 2 + 1)

    counts = {}
    for colour_count, colour in stack.getcolors(1 << 24):
        counts[colour] = colour_count
    unique = list(counts)
    every_colour = picture_of(unique)
    matched = every_colour.quantize(palette=palette_image(first), dither=Image.Dither.NONE).convert("RGB")
    error = FLATTENED(ImageChops.difference(every_colour, matched).convert("L"))
    missed = []
    for colour, colour_error in zip(unique, error):
        if colour_error > MISS:
            missed.extend([colour] * counts[colour])
    colours = first + (choose(picture_of(missed), COLOURS - COLOURS // 2 - 1) if missed else [])
    return palette_image(colours), colours


def main(arguments):
    if arguments[:1] in (["-h"], ["--help"]):
        print(__doc__.strip())
        return 0
    size = None
    if arguments[:1] == ["--size"] and len(arguments) > 1:
        size, arguments = parse_size(arguments[1]), arguments[2:]
    if len(arguments) < 2:
        print(USAGE, file=sys.stderr)
        return 2
    output, frame_arguments = arguments[0], arguments[1:]
    frames, durations = load_frames(frame_arguments, size)
    palette, colours = shared_palette(frames)
    indexed = [frame.quantize(palette=palette, dither=Image.Dither.NONE) for frame in frames]
    indexed[0].save(output, save_all=True, append_images=indexed[1:], duration=durations, loop=0,
                    disposal=1, optimize=True, palette=bytes(colours))
    seconds = sum(durations) / 1000
    print(f"{output}: {len(frames)} frames, {seconds:.1f} s, {frames[0].size[0]}x{frames[0].size[1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
