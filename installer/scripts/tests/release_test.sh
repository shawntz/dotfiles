# shellcheck shell=bash
# release.sh and notarize.sh: the real scripts end to end (build-app.sh, make-dmg.sh, notarize.sh),
# with fake swift, codesign, hdiutil, xcrun and spctl. Nothing is uploaded or published.
# Helpers (run, assert_*, use_fakes, new_checkout, …) come from run.sh.

release_dir() { printf '%s\n' "$PKG/build/release/9.8.7"; }
release_dmg() { printf '%s\n' "$(release_dir)/ShawnsDotfiles-9.8.7.dmg"; }

# Sets MANIFEST_TREE and MANIFEST_VERSION from shawn-cli.json, and INFO_* from the app's build-info.json.
read_release() {
    local manifest
    manifest="$(release_dir)/shawn-cli.json"
    [ -f "$manifest" ] || fail "there is no $manifest"
    MANIFEST_TREE="$(plutil -extract sourceTree raw -o - "$manifest")" || fail "shawn-cli.json has no sourceTree"
    MANIFEST_VERSION="$(plutil -extract version raw -o - "$manifest")" || fail "shawn-cli.json has no version"
    read_info_file "$(release_dir)/Shawn's Dotfiles.app/Contents/Resources/build-info.json"
}

test_release_without_notarization_names_the_release_disk_image_and_keeps_stdout_empty() {
    use_fakes swift codesign hdiutil security
    new_checkout repo installer
    run env SIGN_IDENTITY="$FAKE_SHA1" "$PKG/scripts/release.sh"
    assert_status 0
    assert_contains "$ERR" "Gatekeeper blocks the app"
    assert_contains "$ERR" "NOTARY_PROFILE=<your profile> $(printf '%q' "$PKG/scripts/notarize.sh") $(printf '%q' "$(release_dmg)")"
    # Not ready to publish: `release.sh > publish.sh` must not capture a command that uploads it.
    assert_eq "" "$OUT" "stdout"
    assert_contains "$ERR" "Once the disk image is notarized, publish with:"
    assert_contains "$ERR" "gh release create shawn-v9.8.7"
}

test_release_manifest_and_app_record_the_same_content_id() {
    use_fakes swift codesign hdiutil security
    new_checkout repo installer
    run env SIGN_IDENTITY="$FAKE_SHA1" "$PKG/scripts/release.sh"
    assert_status 0
    read_release
    local expected
    expected="$(expected_content_id installer/)"
    case "$expected" in *-*) fail "the fixture should commit all three source paths: $expected" ;; esac
    assert_eq "$expected" "$MANIFEST_TREE" "shawn-cli.json sourceTree"
    assert_eq "$expected" "$INFO_TREE" "build-info.json sourceTree"
    assert_eq "$(git -C "$REPO" rev-parse HEAD)" "$INFO_COMMIT" "build-info.json commit"
    assert_eq 9.8.7 "$MANIFEST_VERSION" "shawn-cli.json version"
}

test_release_with_a_notary_profile_notarizes_the_release_image_and_prints_the_command() {
    use_fakes swift codesign hdiutil security xcrun spctl
    new_checkout repo installer
    run env SIGN_IDENTITY="$FAKE_SHA1" NOTARY_PROFILE=test-profile "$PKG/scripts/release.sh"
    assert_status 0
    assert_contains "$(cat "$FAKE_LOG")" "xcrun notarytool submit $(release_dmg) --keychain-profile test-profile" "xcrun calls"
    assert_contains "$(cat "$FAKE_LOG")" "xcrun stapler staple $(release_dmg)" "xcrun calls"
    assert_contains "$OUT" "gh release create shawn-v9.8.7"
    assert_contains "$OUT" "$(release_dmg)"
    assert_not_contains "$ERR" "not notarized"
}

test_release_refuses_uncommitted_sources() {
    use_fakes swift codesign hdiutil security
    new_checkout repo installer
    printf '// work in progress\n' >>"$PKG/Sources/App/main.swift"
    run env SIGN_IDENTITY="$FAKE_SHA1" "$PKG/scripts/release.sh"
    assert_status 1
    assert_contains "$ERR" "uncommitted changes"
    assert_contains "$ERR" "installer/Sources/App/main.swift"
    [ ! -e "$(release_dir)/shawn-cli.json" ] || fail "wrote a manifest anyway"
}

test_release_with_allow_dirty_records_unknown_sources() {
    use_fakes swift codesign hdiutil security
    new_checkout repo installer
    printf '// work in progress\n' >>"$PKG/Sources/App/main.swift"
    run env SIGN_IDENTITY="$FAKE_SHA1" ALLOW_DIRTY=1 "$PKG/scripts/release.sh"
    assert_status 0
    read_release
    assert_eq "" "$MANIFEST_TREE" "shawn-cli.json sourceTree"
    assert_eq "" "$INFO_TREE" "build-info.json sourceTree"
    assert_eq "$(git -C "$REPO" rev-parse HEAD)" "$INFO_COMMIT" "build-info.json commit"
}

test_release_signed_ad_hoc_is_not_offered_for_publishing() {
    use_fakes swift hdiutil security
    new_checkout repo installer
    run env SIGN_IDENTITY=- "$PKG/scripts/release.sh"
    assert_status 0
    assert_contains "$ERR" "Do not publish it"
    assert_eq "" "$OUT" "stdout"
}

test_notarize_without_a_file_names_the_release_image_when_that_is_what_exists() {
    PKG="$T/pkg"
    make_package "$PKG"
    mkdir -p "$(release_dir)"
    printf 'image\n' >"$(release_dmg)"
    run env NOTARY_PROFILE=test-profile "$PKG/scripts/notarize.sh"
    assert_status 1
    # Absolute, like release.sh's: make -C installer runs this from the repository root too.
    assert_contains "$ERR" "NOTARY_PROFILE=test-profile $(printf '%q' "$PKG/scripts/notarize.sh") $(printf '%q' "$(release_dmg)")"
}

test_notarize_without_a_file_or_an_image_says_how_to_make_one() {
    PKG="$T/pkg"
    make_package "$PKG"
    run env NOTARY_PROFILE=test-profile "$PKG/scripts/notarize.sh"
    assert_status 1
    assert_contains "$ERR" "nothing to notarize at $PKG/build/ShawnsDotfiles-9.8.7.dmg"
    assert_contains "$ERR" "make dmg"
}
