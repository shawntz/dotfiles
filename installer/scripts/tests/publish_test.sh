# shellcheck shell=bash
# publish-release.sh: the real release.sh builds the files (with fake swift, codesign, hdiutil, xcrun
# and spctl), then a fake gh stands in for GitHub. Nothing is uploaded or published.
# Helpers (run, assert_*, use_fakes, new_checkout, …) come from run.sh.

publish_dir() { printf '%s\n' "$PKG/build/release/9.8.7"; }

# A checkout with a release built in it: Developer ID signed and notarized, as far as the fakes say.
notarized_release() {
    use_fakes swift codesign hdiutil security xcrun spctl gh
    new_checkout repo installer
    env SIGN_IDENTITY="$FAKE_SHA1" NOTARY_PROFILE=test-profile "$PKG/scripts/release.sh" >/dev/null 2>&1 ||
        fail "release.sh could not build the fixture"
    : >"$FAKE_LOG"
}

# The same, signed ad hoc with the real codesign, so the disk image has no signature at all.
ad_hoc_release() {
    use_fakes swift hdiutil security gh
    new_checkout repo installer
    env SIGN_IDENTITY=- "$PKG/scripts/release.sh" >/dev/null 2>&1 || fail "release.sh could not build the fixture"
    : >"$FAKE_LOG"
}

gh_calls() { grep '^gh ' "$FAKE_LOG" || true; }

test_publish_uploads_a_notarized_release_to_a_draft_then_publishes_it() {
    notarized_release
    run "$PKG/scripts/publish-release.sh"
    assert_status 0
    local dir commit expected
    dir="$(publish_dir)"
    commit="$(git -C "$REPO" rev-parse HEAD)"
    expected="gh release view shawn-v9.8.7 --repo shawntz/dotfiles --json isDraft --jq .isDraft
gh api repos/shawntz/dotfiles/commits/tags/shawn-v9.8.7 --jq .sha
gh release create shawn-v9.8.7 --repo shawntz/dotfiles --target $commit --title Shawn's Dotfiles 9.8.7 --draft --generate-notes $dir/ShawnsDotfiles-9.8.7.dmg $dir/shawn-9.8.7-macos-arm64.tar.gz $dir/shawn-9.8.7-macos-arm64.tar.gz.sha256 $dir/shawn-cli.json
gh release edit shawn-v9.8.7 --repo shawntz/dotfiles --draft=false"
    assert_eq "$expected" "$(gh_calls)" "gh calls"
    assert_eq "https://github.com/shawntz/dotfiles/releases/tag/shawn-v9.8.7" "$OUT" "stdout"
    assert_contains "$ERR" "notarized:            yes"
    [ ! -e "$FAKE_LOG.notes" ] || fail "a notarized release needs no note about Gatekeeper"
    assert_eq "" "$(ls -A "$TMPDIR")" "what is left in the temp folder"
}

test_publish_refuses_a_disk_image_that_is_not_notarized() {
    ad_hoc_release
    run "$PKG/scripts/publish-release.sh"
    assert_status 1
    assert_contains "$ERR" "Apple has not notarized ShawnsDotfiles-9.8.7.dmg"
    assert_contains "$ERR" "--allow-unnotarized"
    assert_eq "" "$(gh_calls)" "gh calls"
    assert_eq "" "$OUT" "stdout"
}

test_publish_with_allow_unnotarized_says_so_in_the_release_notes() {
    ad_hoc_release
    run "$PKG/scripts/publish-release.sh" --allow-unnotarized
    assert_status 0
    assert_contains "$(gh_calls)" "--draft --generate-notes --notes-file "
    assert_contains "$(gh_calls)" "gh release edit shawn-v9.8.7 --repo shawntz/dotfiles --draft=false"
    local notes
    notes="$(cat "$FAKE_LOG.notes")"
    assert_contains "$notes" "Apple has not notarized this build"
    assert_contains "$notes" "https://github.com/shawntz/dotfiles/blob/HEAD/installer/README.md#if-macos-wont-open-it"
    assert_contains "$ERR" "notarized:            no"
    assert_eq "" "$(ls -A "$TMPDIR")" "what is left in the temp folder (the notes file must not be)"
}

test_publish_of_a_developer_id_image_without_a_ticket_needs_the_flag_too() {
    use_fakes swift codesign hdiutil security xcrun spctl gh
    new_checkout repo installer
    env SIGN_IDENTITY="$FAKE_SHA1" "$PKG/scripts/release.sh" >/dev/null 2>&1 || fail "release.sh could not build the fixture"
    : >"$FAKE_LOG"
    export FAKE_TICKET=none
    run "$PKG/scripts/publish-release.sh"
    assert_status 1
    assert_contains "$ERR" "disk image signature: $FAKE_IDENTITY_NAME"
    assert_contains "$ERR" "Apple has not notarized"
    assert_eq "" "$(gh_calls)" "gh calls"
}

test_publish_leaves_a_published_release_alone() {
    notarized_release
    export FAKE_GH_RELEASE=published
    run "$PKG/scripts/publish-release.sh"
    assert_status 0
    assert_contains "$ERR" "shawn-v9.8.7 is already published on shawntz/dotfiles"
    assert_not_contains "$(gh_calls)" "release create" "gh calls"
    assert_not_contains "$(gh_calls)" "release delete" "gh calls"
    assert_eq "" "$OUT" "stdout"
}

test_publish_replaces_a_draft_that_a_failed_run_left() {
    notarized_release
    export FAKE_GH_RELEASE=draft
    run "$PKG/scripts/publish-release.sh"
    assert_status 0
    local calls
    calls="$(gh_calls | awk '{ print $2, $3 }' | tr '\n' ',')"
    assert_eq "release view,release delete,api repos/shawntz/dotfiles/commits/tags/shawn-v9.8.7,release create,release edit," "$calls" "order of the gh calls"
    assert_contains "$(gh_calls)" "gh release delete shawn-v9.8.7 --repo shawntz/dotfiles --yes"
}

test_publish_dry_run_prints_the_commands_and_calls_nothing() {
    notarized_release
    run "$PKG/scripts/publish-release.sh" --dry-run
    assert_status 0
    assert_contains "$OUT" "gh release create shawn-v9.8.7 --repo shawntz/dotfiles --target $(git -C "$REPO" rev-parse HEAD)"
    assert_contains "$OUT" "gh release edit shawn-v9.8.7 --repo shawntz/dotfiles --draft=false"
    assert_eq "" "$(gh_calls)" "gh calls"
}

test_publish_dry_run_shows_the_notes_it_would_attach() {
    ad_hoc_release
    run "$PKG/scripts/publish-release.sh" --dry-run --allow-unnotarized
    assert_status 0
    assert_contains "$OUT" "--draft --generate-notes --notes-file "
    assert_contains "$ERR" "It would hold:"
    assert_contains "$ERR" "    Apple has not notarized this build"
    assert_eq "" "$(gh_calls)" "gh calls"
}

# Deleting a release keeps its tag, and gh then puts the next release of that name on the old tag.
test_publish_refuses_a_tag_that_points_at_another_commit() {
    notarized_release
    export FAKE_GH_TAG=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    run "$PKG/scripts/publish-release.sh"
    assert_status 1
    assert_contains "$ERR" "the tag shawn-v9.8.7 is already on shawntz/dotfiles and points at aaaaaaaaaaaa, not at $(git -C "$REPO" rev-parse HEAD | cut -c1-12)"
    assert_contains "$ERR" "git push --delete origin shawn-v9.8.7"
    assert_not_contains "$(gh_calls)" "release create" "gh calls"
    assert_eq "" "$OUT" "stdout"
}

test_publish_goes_ahead_when_the_tag_is_already_on_this_commit() {
    notarized_release
    FAKE_GH_TAG="$(git -C "$REPO" rev-parse HEAD)"
    export FAKE_GH_TAG
    run "$PKG/scripts/publish-release.sh"
    assert_status 0
    assert_contains "$(gh_calls)" "gh release edit shawn-v9.8.7 --repo shawntz/dotfiles --draft=false"
}

test_publish_stops_when_github_does_not_answer() {
    notarized_release
    export FAKE_GH_RELEASE=error
    run "$PKG/scripts/publish-release.sh"
    assert_status 1
    assert_contains "$ERR" "HTTP 502"
    assert_contains "$ERR" "could not ask GitHub whether shawn-v9.8.7 is released"
    assert_not_contains "$(gh_calls)" "release create" "gh calls"
}

test_publish_refuses_a_checkout_with_uncommitted_sources() {
    notarized_release
    printf '// work in progress\n' >>"$PKG/Sources/App/main.swift"
    run "$PKG/scripts/publish-release.sh"
    assert_status 1
    assert_contains "$ERR" "installer/Sources/App/main.swift"
    assert_contains "$ERR" "have uncommitted changes (listed above), so HEAD does not say what this checkout holds"
    assert_eq "" "$(gh_calls)" "gh calls"
}

test_publish_refuses_files_built_for_another_repo() {
    notarized_release
    run env RELEASE_REPO=someone/fork "$PKG/scripts/publish-release.sh"
    assert_status 1
    assert_contains "$ERR" "shawn-cli.json has url"
    assert_contains "$ERR" "https://github.com/someone/fork/releases/download/shawn-v9.8.7/shawn-9.8.7-macos-arm64.tar.gz"
    assert_eq "" "$(gh_calls)" "gh calls"
}

test_publish_refuses_a_tarball_that_does_not_match_its_checksum() {
    notarized_release
    printf 'something else\n' >>"$(publish_dir)/shawn-9.8.7-macos-arm64.tar.gz"
    run "$PKG/scripts/publish-release.sh"
    assert_status 1
    assert_contains "$ERR" "shawn-cli.json does not hold the checksum of shawn-9.8.7-macos-arm64.tar.gz"
    assert_eq "" "$(gh_calls)" "gh calls"
}

test_publish_refuses_when_the_checkout_holds_other_sources() {
    notarized_release
    printf '// a later change\n' >>"$PKG/Sources/App/main.swift"
    git -C "$REPO" commit -q -am "change the sources"
    run "$PKG/scripts/publish-release.sh"
    assert_status 1
    assert_contains "$ERR" "built from other sources than this checkout holds at HEAD"
    assert_eq "" "$(gh_calls)" "gh calls"
}

test_publish_says_what_to_run_when_the_draft_cannot_be_published() {
    notarized_release
    export FAKE_GH_FAIL=edit
    run "$PKG/scripts/publish-release.sh"
    assert_status 1
    assert_contains "$ERR" "the draft of shawn-v9.8.7 is uploaded but gh could not publish it"
    assert_contains "$ERR" "gh release edit shawn-v9.8.7 --repo shawntz/dotfiles --draft=false"
    assert_eq "" "$OUT" "stdout"
}

test_publish_without_a_built_release_says_to_build_one() {
    use_fakes gh
    new_checkout repo installer
    run "$PKG/scripts/publish-release.sh"
    assert_status 1
    assert_contains "$ERR" "there is no $(publish_dir)"
    assert_contains "$ERR" "scripts/release.sh"
    assert_eq "" "$(gh_calls)" "gh calls"
}
