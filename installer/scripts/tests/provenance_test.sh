# shellcheck shell=bash
# build-info.json: which committed sources build-app.sh says the app was built from.
# Real lipo, ditto, plutil and ad hoc codesign; the fake swift stands in for SwiftPM.
# Helpers (run, assert_*, use_fakes, new_checkout, …) come from run.sh.

APP_NAME_IN_TESTS="Shawn's Dotfiles.app"

build_app() {
    run env SIGN_IDENTITY=- OUTPUT_DIR="$T/out" "$PKG/scripts/build-app.sh"
}

# Sets INFO_VERSION, INFO_COMMIT and INFO_TREE from the built app's build-info.json; fails the test
# when the file or one of its keys is missing (an empty value is fine).
read_build_info() {
    read_info_file "$T/out/$APP_NAME_IN_TESTS/Contents/Resources/build-info.json"
}

test_build_info_records_the_committed_sources_of_a_package_in_a_subfolder() {
    use_fakes swift security
    new_checkout repo installer
    build_app
    assert_status 0
    read_build_info
    local expected
    expected="$(git -C "$REPO" rev-parse HEAD:installer/Sources),$(git -C "$REPO" rev-parse HEAD:installer/Package.swift),$(git -C "$REPO" rev-parse HEAD:installer/Package.resolved)"
    assert_eq "$expected" "$INFO_TREE" "sourceTree"
    assert_eq "$(expected_content_id installer/)" "$INFO_TREE" "sourceTree (as the CLI computes it)"
    assert_eq "$(git -C "$REPO" rev-parse HEAD)" "$INFO_COMMIT" "commit"
    assert_eq 9.8.7 "$INFO_VERSION" "version"
    # Written before signing: a file added after it would break the seal.
    codesign --verify --deep --strict "$T/out/$APP_NAME_IN_TESTS" || fail "the signature does not cover build-info.json"
    assert_contains "$ERR" "committed at"
}

test_build_info_records_the_committed_sources_of_a_package_at_the_repository_root() {
    use_fakes swift security
    new_checkout repo .
    git -C "$REPO" rm -q Package.resolved
    git -C "$REPO" commit -q -m "no Package.resolved"
    build_app
    assert_status 0
    read_build_info
    assert_eq "$(git -C "$REPO" rev-parse HEAD:Sources),$(git -C "$REPO" rev-parse HEAD:Package.swift),-" "$INFO_TREE" "sourceTree"
    assert_eq "$(git -C "$REPO" rev-parse HEAD)" "$INFO_COMMIT" "commit"
}

test_build_info_has_no_source_tree_when_a_source_file_is_modified() {
    use_fakes swift security
    new_checkout repo installer
    printf '// work in progress\n' >>"$PKG/Sources/App/main.swift"
    build_app
    assert_status 0
    read_build_info
    assert_eq "" "$INFO_TREE" "sourceTree"
    assert_eq "$(git -C "$REPO" rev-parse HEAD)" "$INFO_COMMIT" "commit"
    assert_contains "$ERR" "uncommitted changes"
}

test_build_info_has_no_source_tree_when_package_swift_is_modified() {
    use_fakes swift security
    new_checkout repo installer
    printf '// another dependency\n' >>"$PKG/Package.swift"
    build_app
    assert_status 0
    read_build_info
    assert_eq "" "$INFO_TREE" "sourceTree"
}

test_build_info_has_no_source_tree_for_an_untracked_source_file_even_when_status_hides_them() {
    use_fakes swift security
    new_checkout repo installer
    git -C "$REPO" config status.showUntrackedFiles no
    printf 'let extra = 1\n' >"$PKG/Sources/App/Extra.swift"
    build_app
    assert_status 0
    read_build_info
    assert_eq "" "$INFO_TREE" "sourceTree"
}

test_build_info_ignores_uncommitted_changes_outside_the_sources() {
    use_fakes swift security
    new_checkout repo installer
    printf 'tagline: edited\n' >>"$PKG/config/installer.yaml"
    printf 'notes\n' >"$REPO/README.md"
    build_app
    assert_status 0
    read_build_info
    assert_eq "$(expected_content_id installer/)" "$INFO_TREE" "sourceTree"
}

test_build_info_has_no_source_tree_when_the_sources_change_during_the_build() {
    use_fakes swift security
    new_checkout repo installer
    export FAKE_SWIFT_HOOK="printf '// saved mid-build\n' >>'$PKG/Sources/App/main.swift'"
    build_app
    assert_status 0
    read_build_info
    assert_eq "" "$INFO_TREE" "sourceTree"
}

test_build_info_has_no_source_tree_when_the_sources_are_committed_during_the_build() {
    use_fakes swift security
    new_checkout repo installer
    local before
    before="$(git -C "$REPO" rev-parse HEAD)"
    # The tree is clean again when the build ends, so only comparing it with the tree read before
    # the build shows that the binaries may not match it.
    export FAKE_SWIFT_HOOK="printf '// saved mid-build\n' >>'$PKG/Sources/App/main.swift'; git -C '$REPO' commit -qam mid-build"
    build_app
    assert_status 0
    [ "$(git -C "$REPO" rev-parse HEAD)" != "$before" ] || fail "fixture: the hook should have committed"
    [ -z "$(git -C "$REPO" status --porcelain -- installer/Sources)" ] || fail "fixture: the hook should leave Sources clean"
    read_build_info
    assert_eq "" "$INFO_TREE" "sourceTree"
}

test_build_info_outside_git_records_no_commit_or_source_tree() {
    use_fakes swift security
    PKG="$T/plain"
    make_package "$PKG"
    build_app
    assert_status 0
    read_build_info
    assert_eq "" "$INFO_TREE" "sourceTree"
    assert_eq "" "$INFO_COMMIT" "commit"
    assert_eq 9.8.7 "$INFO_VERSION" "version"
    assert_contains "$ERR" "not a git checkout"
}
