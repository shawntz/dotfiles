# shellcheck shell=bash
# make-media.sh: what it says before it renders anything. Rendering needs the real app and Pillow,
# so `make media` itself is the test of that part.
# Helpers (run, assert_*, use_fakes, make_package, …) come from run.sh.

test_media_needs_an_output_folder() {
    make_package "$T/pkg"
    run "$T/pkg/scripts/make-media.sh"
    assert_status 1
    assert_contains "$ERR" "Usage: scripts/make-media.sh [options] OUTPUT_DIR"

    run "$T/pkg/scripts/make-media.sh" --help
    assert_status 0
    local file
    for file in tour.gif sheets.gif welcome.png finished.png icon-256.png; do
        assert_contains "$OUT" "$file" "--help"
    done
}

test_media_without_pillow_says_how_to_get_it_and_builds_nothing() {
    use_fakes swift
    make_package "$T/pkg"
    # A python3 without Pillow: every import fails.
    printf '#!/bin/sh\nexit 1\n' >"$T/bin/python3"
    chmod +x "$T/bin/python3"
    mkdir -p "$T/tmp"
    run env TMPDIR="$T/tmp" "$T/pkg/scripts/make-media.sh" "$T/media"
    assert_status 1
    assert_contains "$ERR" "Pillow is not installed for $T/bin/python3"
    assert_contains "$ERR" "python3 -m pip install Pillow"
    assert_eq "" "$(cat "$FAKE_LOG")" "swift calls"
    [ ! -e "$T/media" ] || fail "it made $T/media"
    [ -z "$(ls -A "$T/tmp")" ] || fail "it left $(ls -A "$T/tmp") in TMPDIR"
}

test_media_without_python_says_so() {
    make_package "$T/pkg"
    run env PYTHON=no-such-python "$T/pkg/scripts/make-media.sh" "$T/media"
    assert_status 1
    assert_contains "$ERR" "cannot find no-such-python"
}
