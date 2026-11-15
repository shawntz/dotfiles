# shellcheck shell=bash
# check-config-gitignore.sh: config files that git would leave out of a commit.
# Helpers (run, assert_*, new_checkout, …) come from run.sh.

# Rules from the repository's root .gitignore that have hidden config files before.
root_rules() {
    printf '.DS_Store\nIcon?\n*.log\n*.lock\nbuild/\ntarget/\ndist/\n.zshrc\n' >"$REPO/.gitignore"
}

check_config() {
    run "$PKG/scripts/check-config-gitignore.sh" "$PKG/config"
}

test_gitignore_check_passes_a_config_git_keeps() {
    new_checkout repo installer
    root_rules
    mkdir -p "$PKG/config/webapp-icons" "$PKG/config/files/zsh"
    printf 'png' >"$PKG/config/webapp-icons/linear.png"
    printf 'zsh' >"$PKG/config/files/zsh/zshrc"
    printf 'finder' >"$PKG/config/.DS_Store"
    check_config
    assert_status 0
}

test_gitignore_check_reports_ignored_config_files_as_a_mac_sees_them() {
    new_checkout repo installer
    root_rules
    # A CI runner's checkout is case-sensitive; the check must still see what a Mac sees.
    git -C "$REPO" config core.ignorecase false
    mkdir -p "$PKG/config/icons" "$PKG/config/webapp-icons" "$PKG/config/files/zsh"
    printf 'png' >"$PKG/config/icons/linear.png"
    printf 'png' >"$PKG/config/webapp-icons/carbon.png"
    printf 'zsh' >"$PKG/config/files/zsh/.zshrc"
    printf 'finder' >"$PKG/config/.DS_Store"
    check_config
    assert_status 1
    assert_contains "$ERR" "icons/linear.png  (.gitignore:2:Icon?)"
    assert_contains "$ERR" "files/zsh/.zshrc  (.gitignore:8:.zshrc)"
    assert_not_contains "$ERR" "webapp-icons/carbon.png"
    assert_not_contains "$ERR" ".DS_Store"
}

test_gitignore_check_reports_a_rule_that_hides_a_documented_folder_while_it_is_empty() {
    new_checkout repo installer
    root_rules
    printf 'webapp-*/\n' >>"$REPO/.gitignore"
    check_config
    assert_status 1
    assert_contains "$ERR" "webapp-icons/example.png"
}

test_gitignore_check_outside_git_has_nothing_to_check() {
    PKG="$T/plain"
    make_package "$PKG"
    check_config
    assert_status 0
    assert_contains "$ERR" "not in a git checkout"
}

# git check-ignore --verbose also prints paths whose last matching rule is a "!" exception, which
# git keeps; the check must not count those as hidden.
test_gitignore_check_accepts_a_folder_wide_exception_that_keeps_files() {
    new_checkout repo installer
    root_rules
    mkdir -p "$PKG/config/files/zsh"
    printf 'zsh' >"$PKG/config/files/zsh/.zshrc"
    # Keeps everything under files/, including the .zshrc the root .zshrc rule would hide.
    printf '!config/files/**\n' >>"$PKG/.gitignore"
    [ -n "$(git -C "$REPO" status --porcelain --untracked-files=all -- installer/config/files/zsh/.zshrc)" ] ||
        fail "fixture: git should keep files/zsh/.zshrc"
    check_config
    assert_status 0
    assert_not_contains "$ERR" "!config/files/**"
    assert_contains "$ERR" "git keeps every file in $PKG/config"
}

test_gitignore_check_accepts_an_exception_for_the_whole_config() {
    new_checkout repo installer
    root_rules
    mkdir -p "$PKG/config/icons"
    printf 'png' >"$PKG/config/icons/linear.png"
    printf '!config/**\n.DS_Store\n' >>"$PKG/.gitignore"
    [ -n "$(git -C "$REPO" status --porcelain --untracked-files=all -- installer/config/icons/linear.png)" ] ||
        fail "fixture: git should keep icons/linear.png"
    check_config
    assert_status 0
    assert_not_contains "$ERR" "!config/**"
    assert_contains "$ERR" "git keeps every file in $PKG/config"
}

test_gitignore_check_reports_what_an_exception_does_not_keep() {
    new_checkout repo installer
    root_rules
    printf 'fun/\nwebapp-*/\n' >>"$REPO/.gitignore"
    mkdir -p "$PKG/config/files/zsh" "$PKG/config/webapp-icons"
    printf 'zsh' >"$PKG/config/files/zsh/.zshrc"
    printf 'png' >"$PKG/config/webapp-icons/linear.png"
    # The first keeps files/; the second cannot, because git never looks inside a folder it ignores.
    printf '!config/files/**\n!config/webapp-icons/linear.png\n' >>"$PKG/.gitignore"
    [ -z "$(git -C "$REPO" status --porcelain --untracked-files=all -- installer/config/webapp-icons)" ] ||
        fail "fixture: git should leave webapp-icons/linear.png out"
    check_config
    assert_status 1
    assert_contains "$ERR" "webapp-icons/linear.png  (.gitignore:10:webapp-*/)"
    assert_contains "$ERR" "webapp-icons/example.png  (.gitignore:10:webapp-*/)"
    assert_contains "$ERR" "fun/header.txt  (.gitignore:9:fun/)"
    assert_not_contains "$ERR" "files/zsh/.zshrc"
    assert_not_contains "$ERR" "files/example/"
    assert_not_contains "$ERR" "(installer/.gitignore:"
}

test_gitignore_check_fails_when_git_check_ignore_fails() {
    new_checkout repo installer
    local real_git
    real_git="$(command -v git)"
    # The real git, except that check-ignore fails as on a broken repository.
    cat >"$T/bin/git" <<EOF
#!/bin/bash
for arg in "\$@"; do [ "\$arg" != check-ignore ] || { echo "fatal: broken" >&2; exit 128; }; done
exec $(printf '%q' "$real_git") "\$@"
EOF
    chmod +x "$T/bin/git"
    check_config
    assert_status 1
    assert_contains "$ERR" "git check-ignore failed in $PKG/config"
    assert_not_contains "$ERR" "git keeps every file"
}
