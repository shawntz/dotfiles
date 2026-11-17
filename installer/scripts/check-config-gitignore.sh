#!/bin/bash
# Fails when git would leave part of the config out of a commit. Run with --help for details.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
    cat <<EOF
Usage: scripts/check-config-gitignore.sh [CONFIG_DIR]

Checks, read-only, that git keeps everything in CONFIG_DIR (default config/):
  1. no file in it is ignored by a .gitignore (or your global git excludes), because 'git add'
     and 'shawn pr' skip ignored files without a word, so they never reach GitHub or other Macs;
  2. no ignore rule hides a place the README tells you to put things (steps/, files/, skills/,
     webapp-icons/, fun/), even while that folder is empty.
Finder's .DS_Store files are expected to be ignored and are not reported.

git runs with core.ignorecase=true, as on a Mac, so a case-sensitive checkout (a CI runner) sees
what a Mac sees: there the repo's 'Icon?' rule also matches a folder named "icons".
Outside a git checkout there is nothing to check.
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" "Run scripts/check-config-gitignore.sh --help for the options." ;;
esac
[ $# -le 1 ] || die "check one config directory at a time"

CONFIG_DIR="$(absolute_path "${1:-$INSTALLER_ROOT/config}")"
[ -d "$CONFIG_DIR" ] || die "no config directory at $CONFIG_DIR"
command -v git >/dev/null 2>&1 || die "git is missing" "Install the Command Line Tools: xcode-select --install"
if [ "$(git -C "$CONFIG_DIR" rev-parse --is-inside-work-tree 2>/dev/null)" != true ]; then
    note "$CONFIG_DIR is not in a git checkout; nothing to check"
    exit 0
fi

# core.quotePath=false: names with accents are passed between the two git commands as they are.
GIT=(git -C "$CONFIG_DIR" -c core.ignorecase=true -c core.quotePath=false)

# Runs 'git check-ignore --no-index --stdin [OPTION]' on stdin and prints what it prints.
check_ignore() {
    local output status=0
    output="$("${GIT[@]}" check-ignore --no-index --stdin "$@")" || status=$?
    # 1 means "none of them is ignored"; anything above it is git failing.
    [ "$status" -le 1 ] || die "git check-ignore failed in $CONFIG_DIR"
    [ -z "$output" ] || printf '%s\n' "$output"
}

# Prints "<path>  (<rule>)" for each path on stdin that git ignores. Paths are relative to CONFIG_DIR.
# --verbose also prints the paths whose last matching rule is a "!" exception, which git keeps, so
# the plain call picks the ignored paths first and --verbose only names their rules.
explain_ignored() {
    local paths
    paths="$(check_ignore)" || return
    [ -z "$paths" ] ||
        printf '%s\n' "$paths" | check_ignore --verbose | awk -F'\t' '{ printf "%s  (%s)\n", $2, $1 }'
}

problems=0

listing="$("${GIT[@]}" ls-files --others --ignored --exclude-standard -- .)" || die "git ls-files failed in $CONFIG_DIR"
ignored="$(printf '%s\n' "$listing" | grep -Ev '(^|/)\.DS_Store$' || true)"
if [ -n "$ignored" ]; then
    problems=1
    printf '%serror:%s git ignores these files in %s, so commits and shawn pr leave them out:\n' "$_red" "$_reset" "$CONFIG_DIR" >&2
    printf '%s\n' "$ignored" | explain_ignored | sed 's/^/       /' >&2
    printf '       Rename or move each one (the rule that hides it is in parentheses), add a "!" exception for its folder to installer/.gitignore, or delete it if it is junk.\n' >&2
fi

# One made-up file in each documented place.
PROBES=(
    installer.yaml cli.yaml steps/99-example.yaml
    files/example/settings.json files/example/.config
    skills/example/SKILL.md skills/example/scripts/run.py
    webapp-icons/example.png webapp-icons/example.icns
    fun/header.txt fun/quotes.yaml fun/sprites/example.yaml fun/voices/example.yaml fun/images/example.png
)
hidden="$(printf '%s\n' "${PROBES[@]}" | explain_ignored)"
if [ -n "$hidden" ]; then
    problems=1
    printf '%serror:%s an ignore rule hides places the README says to put config files:\n' "$_red" "$_reset" >&2
    printf '%s\n' "$hidden" | sed 's/^/       /' >&2
    printf '       Narrow that rule, or add a "!" exception for the folder to installer/.gitignore.\n' >&2
fi

[ "$problems" = 0 ] || exit 1
info "git keeps every file in $CONFIG_DIR"
