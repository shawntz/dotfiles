# shellcheck shell=bash
# make-dmg.sh: which identity signs the disk image. The fake codesign refuses an ambiguous name,
# as the real one does when a renewed Developer ID certificate shares the old one's name.
# Helpers (run, assert_*, use_fakes, make_package, …) come from run.sh.

# A stand-in for a built app at $T/build: only its Info.plist matters to make-dmg.sh.
fake_built_app() {
    local app="$T/build/Dotfiles.app"
    mkdir -p "$app/Contents/MacOS"
    plutil -create xml1 "$app/Contents/Info.plist"
    plutil -insert CFBundleShortVersionString -string 9.8.7 "$app/Contents/Info.plist"
}

leaf_certificate_sha1() {
    printf 'leaf certificate of %s\n' "$FAKE_IDENTITY_NAME" | shasum -a 1 | awk '{ print toupper($1) }'
}

test_dmg_is_signed_by_the_hash_of_the_certificate_that_signed_the_app() {
    use_fakes codesign hdiutil security
    make_package "$T/pkg"
    fake_built_app
    run "$T/pkg/scripts/make-dmg.sh" --output "$T/build"
    assert_status 0
    local log
    log="$(cat "$FAKE_LOG")"
    assert_contains "$log" "--sign $(leaf_certificate_sha1) " "codesign calls"
    assert_not_contains "$log" "--sign $FAKE_IDENTITY_NAME" "codesign calls"
    assert_contains "$ERR" "Signing the disk image with $FAKE_IDENTITY_NAME"
    assert_eq "$T/build/ShawnsDotfiles-9.8.7.dmg" "$OUT" "stdout"
    [ -f "$T/build/ShawnsDotfiles-9.8.7.dmg" ] || fail "no disk image"
}

test_dmg_is_signed_with_SIGN_IDENTITY_when_it_is_set() {
    use_fakes codesign hdiutil security
    make_package "$T/pkg"
    fake_built_app
    run env SIGN_IDENTITY="$FAKE_SHA1" "$T/pkg/scripts/make-dmg.sh" --output "$T/build"
    assert_status 0
    assert_contains "$(cat "$FAKE_LOG")" "--sign $FAKE_SHA1 " "codesign calls"
}

test_dmg_of_an_ad_hoc_app_is_left_unsigned() {
    use_fakes codesign hdiutil security
    export FAKE_SIGNATURE=adhoc
    make_package "$T/pkg"
    fake_built_app
    run "$T/pkg/scripts/make-dmg.sh" --output "$T/build"
    assert_status 0
    assert_not_contains "$(cat "$FAKE_LOG")" "--sign" "codesign calls"
    assert_contains "$ERR" "left unsigned"
}

test_dmg_packs_the_app_the_shortcut_and_what_gives_the_window_its_look() {
    use_fakes codesign hdiutil security
    export FAKE_SIGNATURE=adhoc
    make_package "$T/pkg"
    fake_built_app
    run "$T/pkg/scripts/make-dmg.sh" --output "$T/build"
    assert_status 0
    local log
    log="$(cat "$FAKE_LOG")"
    # The layout file has its own name by the time the image is unmounted, and nothing else is there.
    assert_contains "$log" "hdiutil holds: .DS_Store .background.tiff Applications Dotfiles.app " "hdiutil calls"
    assert_contains "$log" "hdiutil create -quiet -volname Dotfiles -srcfolder " "hdiutil calls"
    assert_contains "$log" "hdiutil attach -quiet -nobrowse -noautoopen -noverify -mountpoint " "hdiutil calls"
    assert_contains "$log" "-format UDZO -imagekey zlib-level=9" "hdiutil calls"
    # The app is checked while the image is mounted.
    assert_contains "$log" "codesign --verify --deep --strict $T/build/.make-dmg." "codesign calls"
    local left
    for left in "$T/build"/* "$T/build"/.[!.]*; do
        case "$(basename "$left")" in
            Dotfiles.app|ShawnsDotfiles-9.8.7.dmg|".[!.]*") ;;
            *) fail "it left $left in the output folder" ;;
        esac
    done
}

test_dmg_without_the_window_art_says_how_to_draw_it() {
    use_fakes codesign hdiutil security
    make_package "$T/pkg"
    fake_built_app
    rm "$T/pkg/Resources/dmg/DS_Store"
    run "$T/pkg/scripts/make-dmg.sh" --output "$T/build"
    assert_status 1
    assert_contains "$ERR" "there is no $T/pkg/Resources/dmg/DS_Store"
    assert_contains "$ERR" "Draw the disk image's window first: scripts/make-dmg-art.sh"
    assert_not_contains "$(cat "$FAKE_LOG")" "hdiutil" "tool calls"
}

test_dmg_refuses_window_art_drawn_for_another_app_name() {
    use_fakes codesign hdiutil security
    make_package "$T/pkg"
    sed -i '' 's/^APP_NAME="Dotfiles"$/APP_NAME="Lumps"/' "$T/pkg/scripts/common.sh"
    mkdir -p "$T/build/Lumps.app/Contents/MacOS"
    plutil -create xml1 "$T/build/Lumps.app/Contents/Info.plist"
    plutil -insert CFBundleShortVersionString -string 9.8.7 "$T/build/Lumps.app/Contents/Info.plist"
    run "$T/pkg/scripts/make-dmg.sh" --output "$T/build"
    assert_status 1
    assert_contains "$ERR" "$T/pkg/Resources/dmg/DS_Store has no place for Lumps.app"
    assert_contains "$ERR" "Draw it again: scripts/make-dmg-art.sh"
    assert_not_contains "$(cat "$FAKE_LOG")" "hdiutil" "tool calls"
}

test_dmg_refuses_window_art_whose_app_name_only_ends_like_this_one() {
    use_fakes codesign hdiutil security
    make_package "$T/pkg"
    # The layout file places Dotfiles.app, whose name ends in files.app.
    sed -i '' 's/^APP_NAME="Dotfiles"$/APP_NAME="files"/' "$T/pkg/scripts/common.sh"
    mkdir -p "$T/build/files.app/Contents/MacOS"
    plutil -create xml1 "$T/build/files.app/Contents/Info.plist"
    plutil -insert CFBundleShortVersionString -string 9.8.7 "$T/build/files.app/Contents/Info.plist"
    run "$T/pkg/scripts/make-dmg.sh" --output "$T/build"
    assert_status 1
    assert_contains "$ERR" "$T/pkg/Resources/dmg/DS_Store has no place for files.app"
}

test_release_help_lines_up_the_app_with_the_other_files() {
    make_package "$T/pkg"
    run "$T/pkg/scripts/release.sh" --help
    assert_status 0
    assert_contains "$OUT" "  Dotfiles.app                              for Apple silicon (arm64), signed"
    assert_contains "$OUT" "  ShawnsDotfiles-<version>.dmg              notarized when NOTARY_PROFILE is set"
}

test_dmg_that_cannot_be_mounted_leaves_nothing_behind() {
    use_fakes codesign hdiutil security
    export FAKE_SIGNATURE=adhoc FAKE_HDIUTIL_ATTACH_FAILS=1
    make_package "$T/pkg"
    fake_built_app
    run "$T/pkg/scripts/make-dmg.sh" --output "$T/build"
    assert_status 1
    assert_contains "$ERR" "hdiutil could not mount the new disk image"
    assert_not_contains "$(cat "$FAKE_LOG")" "hdiutil detach" "hdiutil calls"
    [ ! -e "$T/build/ShawnsDotfiles-9.8.7.dmg" ] || fail "it made a disk image"
    local left
    for left in "$T/build"/.make-dmg.*; do
        [ ! -e "$left" ] || fail "it left $left"
    done
}
