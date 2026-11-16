# shellcheck shell=bash
# make-dmg-art.sh and make-dsstore.py: what they say before they draw anything. Drawing needs the real
# app and two Python packages, so `make dmg-art` itself is the test of that part, and the Swift tests
# check that the two files in Resources/dmg/ agree with the layout in the code.
# Helpers (run, assert_*, use_fakes, make_package, …) come from run.sh.

test_dmg_art_help_names_both_files() {
    make_package "$T/pkg"
    run "$T/pkg/scripts/make-dmg-art.sh" --help
    assert_status 0
    local part
    for part in background.tiff DS_Store "Resources/dmg/" "ds_store and mac_alias"; do
        assert_contains "$OUT" "$part" "--help"
    done

    run "$T/pkg/scripts/make-dmg-art.sh" --sideways
    assert_status 1
    assert_contains "$ERR" "unknown option: --sideways"
}

test_dmg_art_without_the_packages_says_how_to_get_them_and_builds_nothing() {
    use_fakes swift
    make_package "$T/pkg"
    cp -p "$T/pkg/Resources/dmg/DS_Store" "$T/before"
    # A python3 without the packages: every import fails.
    printf '#!/bin/sh\nexit 1\n' >"$T/bin/python3"
    chmod +x "$T/bin/python3"
    run "$T/pkg/scripts/make-dmg-art.sh"
    assert_status 1
    assert_contains "$ERR" "ds_store and mac_alias are not both installed for $T/bin/python3"
    assert_contains "$ERR" "python3 -m pip install ds_store mac_alias"
    assert_eq "" "$(cat "$FAKE_LOG")" "swift calls"
    cmp -s "$T/before" "$T/pkg/Resources/dmg/DS_Store" || fail "it changed Resources/dmg/DS_Store"
    [ -z "$(ls -A "$TMPDIR")" ] || fail "it left $(ls -A "$TMPDIR") in TMPDIR"
}

test_dmg_art_without_python_says_so() {
    make_package "$T/pkg"
    run env PYTHON=no-such-python "$T/pkg/scripts/make-dmg-art.sh"
    assert_status 1
    assert_contains "$ERR" "cannot find no-such-python"
}

test_dmg_art_needs_a_config_folder() {
    make_package "$T/pkg"
    run "$T/pkg/scripts/make-dmg-art.sh" --config "$T/nowhere"
    assert_status 1
    assert_contains "$ERR" "no installer.yaml in $T/nowhere"
}

test_layout_file_tool_names_what_is_missing_before_it_needs_its_packages() {
    command -v python3 >/dev/null 2>&1 || { echo "skipped: no python3"; return 0; }
    make_package "$T/pkg"
    run python3 "$T/pkg/scripts/make-dsstore.py" --volume Dotfiles --app Dotfiles.app "$T/DS_Store"
    assert_status 1
    assert_contains "$ERR" "make-dsstore.py: missing --picture, --window, --title-bar, --icon-size, --text-size, --app-at, --applications-at, --background"
    [ ! -e "$T/DS_Store" ] || fail "it wrote $T/DS_Store"

    run python3 "$T/pkg/scripts/make-dsstore.py" --help
    assert_status 0
    assert_contains "$OUT" "Writes Finder's layout file for the disk image's window."
}
