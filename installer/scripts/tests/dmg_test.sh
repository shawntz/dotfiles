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
